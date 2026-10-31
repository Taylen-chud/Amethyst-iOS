import UIKit
import UniformTypeIdentifiers

@objc(LauncherNavigationController)
@objcMembers
class LauncherNavigationController: UINavigationController, UIDocumentPickerDelegate, UIPickerViewDataSource, PLPickerViewDelegate, UIPopoverPresentationControllerDelegate {

    var progressViewMain: UIProgressView!
    var progressViewSub: UIProgressView?
    var progressText: UILabel!

    private var versionTextField: PickTextField!
    private var versionPickerView: PLPickerView!
    private var buttonInstall: UIButton?
    private var buttonInstallItem: UIBarButtonItem?
    private var profileSelectedAt = 0
    private var task: MinecraftResourceDownloadTask?
    private var progressVC: UINavigationController?
    private var globalToolbarItems: [UIBarButtonItem]?

    // Download speed / ETA bookkeeping (static locals in the Obj-C version)
    private var lastMsTime: Double = 0
    private var lastSecTime: Int = 0
    private var lastCompletedUnitCount: Int64 = 0

    private let autoresizeMasks: UIView.AutoresizingMask = [.flexibleWidth, .flexibleLeftMargin, .flexibleRightMargin]
    private let progressObserverContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    // MARK: - Profiles (PLProfiles exposes plain methods, not properties)

    private var profilesDict: NSDictionary {
        return (PLProfiles.current().profiles() as AnyObject) as? NSDictionary ?? NSDictionary()
    }

    private func profileInfo(at row: Int) -> NSDictionary? {
        let values = profilesDict.allValues
        guard row >= 0 && row < values.count else { return nil }
        return values[row] as? NSDictionary
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        if responds(to: #selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)) {
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }

        let targetToolbar: UIToolbar = toolbar
        let liquidGlass = hasLiquidGlass

        if liquidGlass {
            versionTextField = PickTextField(frame: CGRect(x: 0, y: 0, width: min(view.frame.width, view.frame.height) * 0.8 - 40, height: 36))
            progressViewMain = UIProgressView(frame: CGRect(x: 20, y: -5, width: versionTextField.frame.width - 40, height: 0))
        } else {
            versionTextField = PickTextField(frame: CGRect(x: 4, y: 4, width: targetToolbar.frame.width * 0.8 - 8, height: targetToolbar.frame.height - 8))
            progressViewMain = UIProgressView(frame: CGRect(x: 0, y: 0, width: targetToolbar.frame.width, height: 0))
        }
        versionTextField.addTarget(versionTextField, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
        versionTextField.autoresizingMask = autoresizeMasks
        versionTextField.placeholder = "Specify version..."
        versionTextField.leftView = UIImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        versionTextField.rightView = UIImageView(image: UIImage(named: "SpinnerArrow")?.resized(to: CGSize(width: 30, height: 30)))
        versionTextField.rightView?.frame = CGRect(x: 0, y: 0, width: versionTextField.frame.height * 0.9, height: versionTextField.frame.height * 0.9)
        versionTextField.leftViewMode = .always
        versionTextField.rightViewMode = .always
        versionTextField.textAlignment = .center

        versionPickerView = PLPickerView()
        versionPickerView.delegate = self
        versionPickerView.dataSource = self

        reloadProfileList()

        versionTextField.inputView = versionPickerView
        versionTextField.setupDoneButton(withTarget: self, action: #selector(versionClosePicker))

        var textFieldContainer: UIView? = nil
        if liquidGlass {
            let container = UIView(frame: versionTextField.frame)
            textFieldContainer = container
            container.addSubview(progressViewMain)
            let playItem = UIBarButtonItem(title: localize("Play"), style: .plain, target: self, action: #selector(performInstallOrShowDetails(_:)))
            playItem.isEnabled = false
            buttonInstallItem = playItem
            DispatchQueue.main.async {
                playItem.buttonGlassView()?.backgroundColor = UIColor(red: 121/255.0, green: 56/255.0, blue: 162/255.0, alpha: 0.5)
            }
            container.addSubview(versionTextField)
            let textFieldItem = UIBarButtonItem(customView: container)
            globalToolbarItems = [textFieldItem, playItem]
        } else {
            let button = UIButton(type: .system)
            buttonInstall = button
            setButtonPointerInteraction(button)
            button.setTitle(localize("Play"), for: .normal)
            button.autoresizingMask = autoresizeMasks
            button.backgroundColor = UIColor(red: 121/255.0, green: 56/255.0, blue: 162/255.0, alpha: 1.0)
            button.layer.cornerRadius = 5
            button.frame = CGRect(x: targetToolbar.frame.width * 0.8, y: 4, width: targetToolbar.frame.width * 0.2, height: targetToolbar.frame.height - 8)
            button.tintColor = .white
            button.isEnabled = false
            button.addTarget(self, action: #selector(performInstallOrShowDetails(_:)), for: .primaryActionTriggered)
            targetToolbar.addSubview(progressViewMain)
            targetToolbar.addSubview(versionTextField)
            targetToolbar.addSubview(button)
        }

        progressViewMain.autoresizingMask = autoresizeMasks
        progressViewMain.isHidden = true
        progressText = UILabel(frame: versionTextField.frame)
        progressText.adjustsFontSizeToFitWidth = true
        progressText.autoresizingMask = autoresizeMasks
        progressText.font = progressText.font.withSize(16)
        progressText.textAlignment = .center
        progressText.isUserInteractionEnabled = false

        if let container = textFieldContainer {
            container.addSubview(progressText)
        } else {
            targetToolbar.addSubview(progressText)
        }

        fetchRemoteVersionList()
        NotificationCenter.default.addObserver(self, selector: #selector(receiveNotification(_:)), name: NSNotification.Name("InstallModpack"), object: nil)

        if BaseAuthenticator.current is MicrosoftAuthenticator {
            // Perform token refreshment on startup
            setInteractionEnabled(false, forDownloading: false)
            let callback: @convention(block) (Any?, Bool) -> Void = { [weak self] status, success in
                // The callback may come from a background queue
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // A nil status means the refresh is finished
                    let text: String? = status.map { String(describing: $0) }
                    self.progressText.text = text
                    if text == nil {
                        self.setInteractionEnabled(true, forDownloading: false)
                    } else if !success {
                        showDialog(localize("Error"), text)
                    }
                }
            }
            // Called by selector, the Swift spelling of -refreshTokenWithCallback: is easy to get wrong
            _ = (BaseAuthenticator.current! as AnyObject).perform(
                NSSelectorFromString("refreshTokenWithCallback:"),
                with: unsafeBitCast(callback, to: AnyObject.self))
        }
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        super.setViewControllers(viewControllers, animated: animated)
        if let first = viewControllers.first, first.toolbarItems == nil, let items = globalToolbarItems {
            first.toolbarItems = items
        }
    }

    // MARK: - Version lists

    func isVersionInstalled(_ versionId: String) -> Bool {
        let localPath = "\(gameDir)/versions/\(versionId)"
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func fetchLocalVersionList() {
        if localVersionList == nil {
            localVersionList = NSMutableArray()
        }
        localVersionList.removeAllObjects()

        let versionPath = "\(gameDir)/versions/"
        let list = (try? FileManager.default.contentsOfDirectory(atPath: versionPath)) ?? []
        for versionId in list {
            if !isVersionInstalled(versionId) { continue }
            localVersionList.add(["id": versionId, "type": "custom"] as NSDictionary)
        }
    }

    private func setInstallButtonEnabled(_ enabled: Bool) {
        buttonInstall?.isEnabled = enabled
        buttonInstallItem?.isEnabled = enabled
    }

    func fetchRemoteVersionList() {
        setInstallButtonEnabled(false)
        remoteVersionList = NSMutableArray(array: [
            ["id": "latest-release", "type": "release"] as NSDictionary,
            ["id": "latest-snapshot", "type": "snapshot"] as NSDictionary
        ])

        guard let url = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let data = data,
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let versions = json["versions"] as? [Any] {
                        remoteVersionList.addObjects(from: versions.compactMap { $0 as? NSDictionary })
                    }
                    NSDebugLog("[VersionList] Got \(remoteVersionList.count) versions")
                    setPrefObject("internal.latest_version", json["latest"])
                } else {
                    NSDebugLog("[VersionList] Warning: Unable to fetch version list: \(error?.localizedDescription ?? "invalid response")")
                }
                self?.setInstallButtonEnabled(true)
            }
        }.resume()
    }

    // Invoked by: startup, instance change event
    func reloadProfileList() {
        // Reload local version list
        fetchLocalVersionList()
        // Reload launcher_profiles.json
        PLProfiles.updateCurrent()
        versionPickerView.reloadAllComponents()
        // Reload selected profile info
        let selectedName = PLProfiles.current().selectedProfileName()
        guard let index = profilesDict.allKeys.firstIndex(where: { ($0 as? String) == selectedName }) else {
            // This instance has no profiles?
            return
        }
        profileSelectedAt = index
        versionPickerView.selectRow(index, inComponent: 0, animated: false)
        pickerView(versionPickerView, didSelectRow: index, inComponent: 0)
    }

    // MARK: - Options

    func enterCustomControls() {
        let vc = CustomControlsViewController()
        vc.modalPresentationStyle = .overFullScreen
        vc.setDefaultCtrl = { name in
            setPrefObject("control.default_ctrl", name)
        }
        vc.getDefaultCtrl = {
            return (getPrefObject("control.default_ctrl") as? String) ?? ""
        }
        present(vc, animated: true)
    }

    func enterModInstaller() {
        let jarType = UTType(mimeType: "application/java-archive") ?? .data
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [jarType], asCopy: true)
        documentPicker.delegate = self
        documentPicker.modalPresentationStyle = .formSheet
        present(documentPicker, animated: true)
    }

    func enterModInstallerWithPath(_ path: String, hitEnterAfterWindowShown hitEnter: Bool) {
        let vc = JavaGUIViewController()
        vc.filepath = path
        vc.setHitEnterAfterWindowShown(hitEnter)
        if vc.requiredJavaVersion == 0 {
            return
        }
        invokeAfterJITEnabled { [weak self] in
            vc.modalPresentationStyle = .fullScreen
            NSLog("[ModInstaller] launching %@", vc.filepath ?? "")
            self?.present(vc, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        enterModInstallerWithPath(url.path, hitEnterAfterWindowShown: false)
    }

    func setInteractionEnabled(_ enabled: Bool, forDownloading downloading: Bool) {
        versionTextField.alpha = enabled ? 1 : 0.2
        versionTextField.isEnabled = enabled
        progressViewMain.isHidden = enabled
        progressText.text = nil
        if downloading {
            let title = localize(enabled ? "Play" : "Details")
            if let button = buttonInstall {
                button.setTitle(title, for: .normal)
                button.isEnabled = true
            } else {
                buttonInstallItem?.title = title
                buttonInstallItem?.isEnabled = true
            }
        } else {
            buttonInstall?.isEnabled = enabled
            buttonInstallItem?.isEnabled = enabled
        }
        UIApplication.shared.isIdleTimerDisabled = !enabled
    }

    // MARK: - Launching

    func launchMinecraft(_ sender: UIView) {
        if !versionTextField.hasText {
            versionTextField.becomeFirstResponder()
            return
        }

        if BaseAuthenticator.current == nil {
            // Present the account selector if none selected
            if let menu = (splitViewController?.viewControllers.first as? UINavigationController)?.viewControllers.first as? LauncherMenuViewController {
                menu.selectAccount(sender)
            }
            return
        }

        setInteractionEnabled(false, forDownloading: true)

        let versionId = (profilesDict[versionTextField.text ?? ""] as? NSDictionary)?["lastVersionId"] as? String ?? ""
        var object: NSDictionary? = nil
        if let list = remoteVersionList {
            for item in list where (item["id"] as? String) == versionId {
                object = item
                break
            }
        }
        let versionObject: NSDictionary = object ?? ["id": versionId, "type": "custom"]

        let newTask = MinecraftResourceDownloadTask()
        task = newTask
        DispatchQueue.global(qos: .default).async { [weak self] in
            newTask.handleError = { [weak self] in
                DispatchQueue.main.async {
                    self?.setInteractionEnabled(true, forDownloading: true)
                    self?.task = nil
                    self?.progressVC = nil
                }
            }
            newTask.downloadVersion(versionObject as? [AnyHashable: Any])
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progressViewMain.observedProgress = newTask.progress
                newTask.progress.addObserver(self, forKeyPath: "fractionCompleted", options: [.initial], context: self.progressObserverContext)
            }
        }
    }

    func performInstallOrShowDetails(_ sender: Any) {
        let usesBarButtonItem = sender is UIBarButtonItem
        if let task = task {
            if progressVC == nil {
                let vc = DownloadProgressViewController(task: task)
                let nav = UINavigationController(rootViewController: vc)
                nav.modalPresentationStyle = .popover
                progressVC = nav
            } else if progressVC?.popoverPresentationController?._isDismissing() == true {
                // FIXME: stock bug? it crashes when users dismisses and presents this vc too fast
                // "UIPopoverPresentationController () should have a non-nil sourceView or barButtonItem set before the presentation occurs."
                return
            }

            if let item = sender as? UIBarButtonItem {
                progressVC?.popoverPresentationController?.barButtonItem = item
            } else if let view = sender as? UIView {
                progressVC?.popoverPresentationController?.sourceView = view
            }
            if let vc = progressVC {
                present(vc, animated: true)
            }
        } else {
            if usesBarButtonItem, let item = sender as? UIBarButtonItem {
                if let glassView = item.buttonGlassView() {
                    launchMinecraft(glassView)
                }
            } else if let view = sender as? UIView {
                launchMinecraft(view)
            }
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context != progressObserverContext {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        // Calculate download speed and ETA
        guard let task = task, let progress = task.textProgress, let mainProgress = task.progress else { return }
        var tv = timeval()
        gettimeofday(&tv, nil)
        let completedUnitCount = Int64(Double(mainProgress.totalUnitCount) * mainProgress.fractionCompleted)
        progress.completedUnitCount = completedUnitCount
        if lastSecTime < Int(tv.tv_sec) {
            let currentTime = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
            let elapsed = currentTime - lastMsTime
            if elapsed > 0 {
                let throughput = Int((Double(completedUnitCount - lastCompletedUnitCount)) / elapsed)
                progress.throughput = throughput
                if throughput > 0 {
                    progress.estimatedTimeRemaining = Double(progress.totalUnitCount - completedUnitCount) / Double(throughput)
                }
            }
            lastCompletedUnitCount = completedUnitCount
            lastSecTime = Int(tv.tv_sec)
            lastMsTime = currentTime
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progressText.text = progress.localizedAdditionalDescription

            if !progress.isFinished { return }
            self.progressVC?.dismiss(animated: false)

            self.progressViewMain.observedProgress = nil
            if let metadata = self.task?.metadata as? [AnyHashable: Any] {
                self.invokeAfterJITEnabled {
                    UIKit_launchMinecraftSurfaceVC(self.view.window, metadata)
                }
            } else {
                self.reloadProfileList()
            }
            self.task = nil
            self.setInteractionEnabled(true, forDownloading: true)
        }
    }

    func receiveNotification(_ notification: Notification) {
        guard notification.name.rawValue == "InstallModpack" else { return }
        setInteractionEnabled(false, forDownloading: true)
        let newTask = MinecraftResourceDownloadTask()
        task = newTask
        let userInfo = notification.userInfo ?? [:]
        let api = notification.object
        let detail = userInfo["detail"] as? [AnyHashable: Any]
        let index = (userInfo["index"] as? NSNumber)?.uintValue ?? 0
        DispatchQueue.global(qos: .default).async { [weak self] in
            newTask.handleError = { [weak self] in
                DispatchQueue.main.async {
                    self?.setInteractionEnabled(true, forDownloading: true)
                    self?.task = nil
                    self?.progressVC = nil
                }
            }
            newTask.startModpackInstall(api, detail: detail, atIndex: index)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progressViewMain.observedProgress = newTask.progress
                newTask.progress.addObserver(self, forKeyPath: "fractionCompleted", options: [.initial], context: self.progressObserverContext)
            }
        }
    }

    // MARK: - JIT

    func invokeAfterJITEnabled(_ handler: @escaping () -> Void) {
        localVersionList = nil
        remoteVersionList = nil
        let hasTrollStoreJIT = getEntitlementValue("jb.pmap_cs.custom_trust")
        let bundleId = Bundle.main.bundleIdentifier ?? ""

        if isJITEnabled(false) {
            ALTServerManager.sharedManager().stopDiscovering()
            handler()
            return
        } else if hasTrollStoreJIT {
            if let url = URL(string: "apple-magnifier://enable-jit?bundle-id=\(bundleId)") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            // Do not return, wait for TrollStore to enable JIT and jump back
        } else if getPrefBool("debug.debug_skip_wait_jit") {
            NSLog("Debug option skipped waiting for JIT. Java might not work.")
            handler()
            return
        } else if #available(iOS 17.4, *) {
            var scriptDataString = ""
            // DeviceHasJITFlags(a | b) is true only when both flags are set
            if DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED) && DeviceHasJITFlags(JIT_FLAG_HAS_TXM) {
                let scriptPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("UniversalJIT26.js")
                if let scriptData = NSData(contentsOfFile: scriptPath) {
                    scriptDataString = "&script-data=" + scriptData.base64EncodedString(options: [])
                }
            }
            if let url = URL(string: "stikjit://enable-jit?bundle-id=\(bundleId)&pid=\(getpid())\(scriptDataString)") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        } else {
            // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
            if let url = URL(string: "sidestore://sidejit-enable?pid=\(getpid())") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }

        progressText.text = localize("launcher.wait_jit.title")

        let alert = UIAlertController(title: localize("launcher.wait_jit.title"),
                                      message: hasTrollStoreJIT ? localize("launcher.wait_jit_trollstore.message") : localize("launcher.wait_jit.message"),
                                      preferredStyle: .alert)
        present(alert, animated: true)

        DispatchQueue.global(qos: .default).async {
            while !isJITEnabled(false) {
                // Perform check for every 200ms
                usleep(1000 * 200)
            }
            DispatchQueue.main.async {
                alert.dismiss(animated: true, completion: handler)
            }
        }
    }

    // MARK: - UIPopoverPresentationControllerDelegate

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }

    // MARK: - UIPickerView stuff

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        profileSelectedAt = row
        (versionTextField.leftView as? UIImageView)?.image = (pickerView as? PLPickerView)?.imageAtRow(row, column: component)
        versionTextField.text = self.pickerView(pickerView, titleForRow: row, forComponent: component)
        PLProfiles.current().setSelectedProfileName(versionTextField.text ?? "")
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return profilesDict.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return profileInfo(at: row)?["name"] as? String
    }

    // PLPickerViewDelegate
    func pickerView(_ pickerView: PLPickerView, enumerateImageView imageView: UIImageView, forRow row: Int, forComponent component: Int) {
        let fallbackImage = UIImage(named: "DefaultProfile")?.resized(to: CGSize(width: 40, height: 40))
        var url: URL? = nil
        if let urlString = profileInfo(at: row)?["icon"] as? String {
            url = URL(string: urlString)
        }
        imageView.setRemoteImage(url, placeholder: fallbackImage)
    }

    func versionClosePicker() {
        versionTextField.endEditing(true)
        pickerView(versionPickerView, didSelectRow: versionPickerView.selectedRow(inComponent: 0), inComponent: 0)
    }

    // MARK: - View controller UI mode

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let sidebarVC = (splitViewController?.viewControllers.first as? UINavigationController)?.viewControllers.first as? LauncherMenuViewController {
            sidebarVC.updateAccountInfo()
        }
        if globalToolbarItems != nil {
            if viewControllers.first?.toolbarItems == nil {
                viewControllers.first?.toolbarItems = globalToolbarItems
            }
            // resize textFieldContainer to fit, need dispatch queue or it freezes for some reason...
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.versionTextField.superview?.frame = CGRect(x: 0, y: 0, width: min(self.view.frame.width, self.view.frame.height) * 0.8 - 40, height: 36)
            }
        }
    }
}
