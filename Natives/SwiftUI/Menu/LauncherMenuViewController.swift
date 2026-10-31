import UIKit

class LauncherMenuCustomItem {
    var title: String
    var imageName: String
    var action: (() -> Void)?
    var vcArray: [UIViewController] = []

    init(title: String, imageName: String, action: (() -> Void)?) {
        self.title = title
        self.imageName = imageName
        self.action = action
    }

    static func vcClass(_ vcClass: UIViewController.Type) -> LauncherMenuCustomItem {
        let vc = vcClass.init()
        let selector = NSSelectorFromString("imageName")
        var imageName = ""
        if vc.responds(to: selector),
           let name = vc.perform(selector)?.takeUnretainedValue() as? String {
            imageName = name
        }
        let item = LauncherMenuCustomItem(title: vc.title ?? "", imageName: imageName, action: nil)
        item.vcArray = [vc]
        return item
    }
}

// The Obj-C side (LauncherMenuViewController.h) calls updateAccountInfo / drawAccountButton / selectAccount:
// on this class, so everything is exposed to Obj-C and the runtime name has no module prefix.
@objc(LauncherMenuViewController)
@objcMembers
class LauncherMenuViewController: UITableViewController, UIPopoverPresentationControllerDelegate {
    var listPath: String = ""
    var accountButton: UIButton?
    var accountBtnItem: UIBarButtonItem?
    var isInitialVc = true

    private var options: [LauncherMenuCustomItem] = []
    private var lastSelectedIndex = 0

    private var contentNavigationController: LauncherNavigationController? {
        guard let viewControllers = splitViewController?.viewControllers, viewControllers.count > 1 else { return nil }
        return viewControllers[1] as? LauncherNavigationController
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        isInitialVc = true

        let titleView = UIImageView(image: UIImage(named: "AppLogo"))
        titleView.contentMode = .scaleAspectFit
        navigationItem.titleView = titleView
        titleView.sizeToFit()

        let pageClasses: [UIViewController.Type] = [
            LauncherNewsViewController.self,
            LauncherProfilesViewController.self,
            LauncherPreferencesViewController.self,
            ModrinthModsViewController.self,
            LauncherResourcePacksViewController.self,
            LauncherShaderPacksViewController.self,
        ]
        options = pageClasses.map { LauncherMenuCustomItem.vcClass($0) }

        if realUIIdiom != .tv {
            options.append(LauncherMenuCustomItem(
                title: localize("launcher.menu.custom_controls"),
                imageName: "MenuCustomControls"
            ) { [weak self] in
                self?.contentNavigationController?.enterCustomControls()
            })
        }

        options.append(LauncherMenuCustomItem(
            title: localize("launcher.menu.execute_jar"),
            imageName: "MenuInstallJar"
        ) { [weak self] in
            self?.contentNavigationController?.enterModInstaller()
        })

        options.append(LauncherMenuCustomItem(
            title: localize("login.menu.sendlogs"),
            imageName: "square.and.arrow.up"
        ) { [weak self] in
            self?.shareLogs()
        })

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd"
        let date = dateFormatter.string(from: Date())
        if ["06-29", "06-30", "07-01"].contains(date) {
            options.append(LauncherMenuCustomItem(
                title: "Technoblade never dies!",
                imageName: ""
            ) { [weak self] in
                guard let self = self else { return }
                openLink(self, URL(string: "https://youtu.be/DPMluEVUqS0")!)
            })
        }

        tableView.separatorStyle = .none

        navigationController?.isToolbarHidden = false
        let toolbarIndicator = UIActivityIndicatorView(style: .medium)
        toolbarIndicator.startAnimating()
        let statusItem = UIBarButtonItem()
        statusItem.tintColor = .label
        toolbarItems = [UIBarButtonItem(customView: toolbarIndicator), statusItem]

        // Setup the account button
        accountBtnItem = drawAccountButton()

        updateAccountInfo()

        let indexPath = IndexPath(row: 1, section: 0)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        self.tableView(self.tableView, didSelectRowAt: indexPath)
        lastSelectedIndex = 1

        checkJITStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        restoreHighlightedSelection()
    }

    func restoreHighlightedSelection() {
        // Restore the selected row when the view appears again
        let indexPath = IndexPath(row: lastSelectedIndex, section: 0)
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }

    func drawAccountButton() -> UIBarButtonItem {
        if accountBtnItem == nil {
            let button = UIButton(type: .custom)
            button.addTarget(self, action: #selector(selectAccount(_:)), for: .primaryActionTriggered)
            button.contentHorizontalAlignment = .left
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
            button.imageView?.contentMode = .scaleAspectFit
            button.titleLabel?.lineBreakMode = .byWordWrapping
            accountButton = button
            accountBtnItem = UIBarButtonItem(customView: button)
        }

        updateAccountInfo()
        return accountBtnItem!
    }

    func selectAccount(_ sender: UIView) {
        let accountList = AccountListViewController()
        let vc: UIViewController = accountList

        accountList.whenDelete = { [weak self] name in
            guard let self = self else { return }
            if (name ?? "") == (getPrefObject("internal.selected_account") as? String ?? "") {
                BaseAuthenticator.current = nil
                setPrefObject("internal.selected_account", "")
                self.updateAccountInfo()
            }
        }
        accountList.whenItemSelected = { [weak self, weak sender] in
            guard let self = self, let sender = sender else { return }
            setPrefObject("internal.selected_account", BaseAuthenticator.current?.authData["username"] ?? "")
            self.updateAccountInfo()
            if sender !== self.accountButton {
                // Called from the play button, so call back to continue
                (sender as? UIControl)?.sendActions(for: .primaryActionTriggered)
            }
        }
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = CGSize(width: 350, height: 250)

        if let popover = vc.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
            popover.permittedArrowDirections = .any
            popover.delegate = accountList
        }
        present(vc, animated: true)
    }

    func updateAccountInfo() {
        let contentSize = contentNavigationController?.view.frame.size ?? .zero
        let wideEnough = (contentSize.width / 3) > 200

        guard let selected = BaseAuthenticator.current?.authData as? [String: Any] else {
            accountButton?.setAttributedTitle(NSAttributedString(string: wideEnough ? localize("login.option.select") : ""), for: .normal)
            accountButton?.setImage(UIImage(named: "DefaultAccount"), for: .normal)
            accountButton?.sizeToFit()
            return
        }

        // Remove the prefix "Demo." if there is
        let username = selected["username"] as? String ?? ""
        let isDemo = username.hasPrefix("Demo.")
        let title = NSMutableAttributedString(string: isDemo ? String(username.dropFirst(5)) : username)

        // Check if we're switching between demo and full mode
        let shouldUpdateProfiles = (getenv("DEMO_LOCK") != nil) != isDemo

        // Reset states
        unsetenv("DEMO_LOCK")
        let ameHome = envString("AME_HOME") ?? ""
        setenv("GAME_DIR", "\(ameHome)/Library/Application Support/minecraft", 1)

        let subtitleText: String
        if isDemo {
            subtitleText = localize("login.option.demo")
            setenv("DEMO_LOCK", "1", 1)
            setenv("GAME_DIR", "\(ameHome)/.demo", 1)
        } else if let gamertag = selected["xboxGamertag"] as? String {
            // Display the Xbox gamertag for online accounts
            subtitleText = gamertag
        } else {
            subtitleText = localize("login.option.local")
        }

        title.append(NSAttributedString(string: "\n"))
        title.append(NSAttributedString(string: subtitleText, attributes: [.font: UIFont.systemFont(ofSize: 12)]))

        accountButton?.setAttributedTitle(wideEnough ? title : NSAttributedString(string: ""), for: .normal)

        // TODO: Add caching mechanism for profile pictures
        let placeholder = UIImage(named: "DefaultAccount")
        var picURL: URL? = nil
        if let urlString = selected["profilePicURL"] as? String {
            picURL = URL(string: urlString.replacingOccurrences(of: "\\/", with: "/"))
        }
        accountButton?.setRemoteImage(picURL, for: .normal, placeholder: placeholder)
        accountButton?.sizeToFit()

        // Update profiles and local version list if needed
        if shouldUpdateProfiles {
            contentNavigationController?.fetchLocalVersionList()
            contentNavigationController?.reloadProfileList()
        }

        // Update tableView whenever we have
        if let tableVC = contentNavigationController?.viewControllers.last as? UITableViewController {
            tableVC.tableView.reloadData()
        }
    }

    func displayProgress(_ status: String?) {
        if let status = status {
            if let items = toolbarItems, items.count > 1 {
                items[1].title = status
            }
        } else {
            (toolbarItems?.first?.customView as? UIActivityIndicatorView)?.stopAnimating()
        }
    }

    func checkJITStatus() {
        if getEntitlementValue("get-task-allow") {
            displayProgress(localize("login.jit.checking"))
            if isJITEnabled(false) {
                displayProgress(localize("login.jit.enabled"))
                displayProgress(nil)
            } else if #available(iOS 17.0, *) {
                // enabling JIT for 17.0+ is done when we actually launch the game
            } else {
                enableJITWithAltKit()
            }
        } else if !NSRunningOnMacCatalyst && getenv("SIMULATOR_DEVICE_NAME") == nil {
            displayProgress(localize("login.jit.fail"))
            displayProgress(nil)
            let alert = UIAlertController(title: localize("login.jit.fail.title"),
                                          message: localize("login.jit.fail.description_unsupported"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: localize("OK"), style: .default) { _ in exit(-1) })
            present(alert, animated: true)
        }
    }

    func enableJITWithAltKit() {
        ALTServerManager.sharedManager().startDiscovering()
        ALTServerManager.sharedManager().autoconnect(completionHandler: { [weak self] connection, error in
            guard let self = self else { return }
            if let error = error {
                NSLog("[AltKit] Could not auto-connect to server. %@", (error as NSError).localizedRecoverySuggestion ?? error.localizedDescription)
                self.displayProgress(localize("login.jit.fail"))
                self.displayProgress(nil)
                return
            }
            connection?.enableUnsignedCodeExecution(completionHandler: { [weak self] success, error in
                guard let self = self else { return }
                if success {
                    NSLog("[AltKit] Successfully enabled JIT compilation!")
                    ALTServerManager.sharedManager().stopDiscovering()
                    self.displayProgress(localize("login.jit.enabled"))
                    self.displayProgress(nil)
                } else {
                    NSLog("[AltKit] Error enabling JIT: %@", (error as NSError?)?.localizedRecoverySuggestion ?? error?.localizedDescription ?? "")
                    self.displayProgress(localize("login.jit.fail"))
                    self.displayProgress(nil)
                }
                connection?.disconnect()
            })
        })
    }

    func shareLogs() {
        let latestlogPath = "file://\(envString("AME_HOME") ?? "")/latestlog.old.txt"
        NSLog("Path is %@", latestlogPath)
        guard let logURL = URL(string: latestlogPath) else { return }

        var activityVC: UIViewController?
        if realUIIdiom != .tv {
            activityVC = UIActivityViewController(activityItems: [logURL], applicationActivities: nil)
        } else {
            dlopen("/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI", RTLD_GLOBAL)
            if let sharingClass = NSClassFromString("SFAirDropSharingViewControllerTV") {
                let allocated = (sharingClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
                let inited = allocated?.perform(NSSelectorFromString("initWithSharingItems:"), with: [logURL])?.takeUnretainedValue()
                activityVC = inited as? UIViewController
            }
        }
        guard let shareVC = activityVC else { return }

        if let titleView = navigationItem.titleView {
            shareVC.popoverPresentationController?.sourceView = titleView
            shareVC.popoverPresentationController?.sourceRect = titleView.bounds
        }
        present(shareVC, animated: true)
    }

    func collectDiagnosticReportItems() -> [URL] {
        guard let home = envString("AME_HOME"), !home.isEmpty else { return [] }
        let fm = FileManager.default
        var items: [URL] = []

        for name in ["latestlog.txt", "latestlog.old.txt", "mobilegl.log"] {
            let path = (home as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) {
                items.append(URL(fileURLWithPath: path))
            }
        }

        let skipDirNames: Set<String> = ["versions", "libraries", "assets", "java_runtimes"]
        var hsErrFound = 0
        if let enumerator = fm.enumerator(at: URL(fileURLWithPath: home),
                                          includingPropertiesForKeys: [.isDirectoryKey],
                                          options: .skipsHiddenFiles,
                                          errorHandler: nil) {
            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = url.lastPathComponent
                if isDir && skipDirNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if !isDir && name.hasPrefix("hs_err_pid") && url.pathExtension == "log" {
                    items.append(url)
                    hsErrFound += 1
                    if hsErrFound >= 3 { break } // don't attach an unbounded number
                }
            }
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let renderer = PLProfiles.resolveKeyForCurrentProfile("renderer") ?? ""
        var info = ""
        info += "Amethyst version: \(version)-\(CONFIG_TYPE)\n"
        info += "Commit: \(CONFIG_COMMIT) (\(CONFIG_BRANCH))\n"
        info += "Device: \(hostModelName())\n"
        info += "OS: \(UIDevice.current.completeOSVersion() ?? "")\n"
        info += "Install type: \(envString("AME_DETECTEDINST") ?? "unknown")\n"
        info += "Renderer: \(renderer)\n"

        let infoPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("amethyst_diagnostic_info.txt")
        do {
            try info.write(toFile: infoPath, atomically: true, encoding: .utf8)
            items.append(URL(fileURLWithPath: infoPath))
        } catch {
            NSLog("[LauncherMenuViewController] Failed to write diagnostic info file: %@", error.localizedDescription)
        }

        return items
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")

        let option = options[indexPath.row]
        cell.textLabel?.text = option.title

        if let origImage = UIImage(systemName: option.imageName) {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
            let image = renderer.image { _ in
                let scaleFactor = 40 / origImage.size.height
                origImage.draw(in: CGRect(x: 20 - origImage.size.width * scaleFactor / 2, y: 0, width: origImage.size.width * scaleFactor, height: 40))
            }
            cell.imageView?.image = image.withRenderingMode(.alwaysTemplate)
        } else {
            cell.imageView?.layer.magnificationFilter = .nearest
            cell.imageView?.layer.minificationFilter = .nearest
            cell.imageView?.image = UIImage(named: option.imageName)?.resized(to: CGSize(width: 40, height: 40))
        }

        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selected = options[indexPath.row]

        if let action = selected.action {
            restoreHighlightedSelection()
            action()
        } else {
            if isInitialVc {
                isInitialVc = false
            } else {
                options[lastSelectedIndex].vcArray = contentNavigationController?.viewControllers ?? []
                contentNavigationController?.setViewControllers(selected.vcArray, animated: false)
                lastSelectedIndex = indexPath.row
            }
            selected.vcArray[0].navigationItem.rightBarButtonItem = accountBtnItem
            selected.vcArray[0].navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
            selected.vcArray[0].navigationItem.leftItemsSupplementBackButton = true
        }
    }
}
