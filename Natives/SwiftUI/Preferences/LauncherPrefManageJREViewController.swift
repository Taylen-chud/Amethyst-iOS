import UIKit
import UniformTypeIdentifiers

// 0 is reserved for default pickers
// INT_MAX is reserved for invalid runtimes
private let defaultJRE = 0
private let invalidJRE = Int(Int32.max)

/// Replaces the NSString + associated object ("internalJRE" / "installing") pairs of the Obj-C version.
private final class JavaRuntimeEntry {
    let name: String
    var isInternal: Bool
    var installing: Bool

    init(name: String, isInternal: Bool = false, installing: Bool = false) {
        self.name = name
        self.isInternal = isInternal
        self.installing = installing
    }
}

/// `WFWorkflowProgressView` (private WorkflowUIServices class, loaded with dlopen in viewDidLoad).
/// Only ever touched as a UIControl plus KVC, so there is no link time reference to the class.
private var currentProgressView: UIControl?

private func jreProgressFraction() -> Double {
    return (currentProgressView?.value(forKey: "fractionCompleted") as? NSNumber)?.doubleValue ?? 0
}

/// `-[NSFileManager nr_getAllocatedSize:ofDirectoryAtURL:error:]`, called through its IMP so the call does not
/// depend on how Swift renames that selector.
private func jreAllocatedSize(ofDirectory directory: String) -> UInt64 {
    var size: UInt64 = 0
    let selector = NSSelectorFromString("nr_getAllocatedSize:ofDirectoryAtURL:error:")
    let manager = FileManager.default
    guard manager.responds(to: selector), let imp = manager.method(for: selector) else { return 0 }
    typealias SizeFunc = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<UInt64>, NSURL, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
    _ = unsafeBitCast(imp, to: SizeFunc.self)(manager, selector, &size, NSURL(fileURLWithPath: directory), nil)
    return size
}

/// Calls the private `-[UIContextMenuInteraction _presentMenuAtLocation:]` straight through its IMP.
private func jrePresentMenu(of interaction: UIContextMenuInteraction) {
    let selector = NSSelectorFromString("_presentMenuAtLocation:")
    guard interaction.responds(to: selector), let imp = interaction.method(for: selector) else { return }
    typealias PresentFunc = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    unsafeBitCast(imp, to: PresentFunc.self)(interaction, selector, .zero)
}

private func jreMutableDictionary(_ value: Any?) -> NSMutableDictionary {
    if let dict = value as? NSMutableDictionary {
        return dict
    }
    if let dict = value as? NSDictionary, let copy = dict.mutableCopy() as? NSMutableDictionary {
        return copy
    }
    return NSMutableDictionary()
}

@objc(LauncherPrefManageJREViewController)
@objcMembers
class LauncherPrefManageJREViewController: UITableViewController, UIContextMenuInteractionDelegate, UIDocumentPickerDelegate {

    private var javaRuntimes: [Int: [JavaRuntimeEntry]] = [:]
    private var sortedJavaVersions: [Int] = []
    private let selectedRTTags = ["1_16_5_older", "1_17_newer", "execute_jar"]
    private var selectedRuntimes = NSMutableDictionary()
    private var currentMenu: UIMenu?
    private var installingIndexPath: IndexPath?

    static var currentInstance: LauncherPrefManageJREViewController? {
        guard let splitVC = currentVC() as? UISplitViewController,
              splitVC.viewControllers.count > 1,
              let nav = splitVC.viewControllers[1] as? LauncherNavigationController else {
            return nil
        }
        return nav.topViewController as? LauncherPrefManageJREViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = localize("preference.title.manage_runtime")

        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"),
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(actionImportRuntime))

        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.keyboardDismissMode = .interactive

        javaRuntimes = [
            defaultJRE: [
                JavaRuntimeEntry(name: "preference.manage_runtime.default.1165"),
                JavaRuntimeEntry(name: "preference.manage_runtime.default.117"),
                JavaRuntimeEntry(name: "launcher.menu.execute_jar"),
            ]
        ]
        sortedJavaVersions = [defaultJRE]

        selectedRuntimes = jreMutableDictionary(getPrefObject("java.java_homes"))

        let internalPath = "\(Bundle.main.bundlePath)/java_runtimes"
        let externalPath = "\(envString("AME_HOME") ?? "")/java_runtimes"
        listJRE(inPath: internalPath, markInternal: true)
        listJRE(inPath: externalPath, markInternal: false)

        // Load WFWorkflowProgressView
        _ = dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL)
    }

    static func actionCancelImportRuntime() {
        guard let splitVC = currentVC() as? UISplitViewController,
              splitVC.viewControllers.count > 1,
              let nav = splitVC.viewControllers[1] as? LauncherNavigationController else { return }
        nav.progressViewMain?.observedProgress?.cancel()
    }

    func actionImportRuntime() {
        let xzType = UTType(mimeType: "application/x-xz") ?? .data
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [xzType])
        documentPicker.delegate = self
        documentPicker.modalPresentationStyle = .formSheet
        present(documentPicker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        let nav = navigationController as? LauncherNavigationController
        nav?.setInteractionEnabled(false, forDownloading: false)

        _ = url.startAccessingSecurityScopedResource()
        let xzSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0

        let totalProgress = Progress(totalUnitCount: xzSize)
        let fileProgress = Progress(totalUnitCount: 0)
        nav?.progressViewMain?.observedProgress = totalProgress
        nav?.progressViewSub?.observedProgress = fileProgress

        DispatchQueue.global().async {
            let path = url.path
            let runtimeName = (String(path.dropLast(7)) as NSString).lastPathComponent
            let outPath = "\(envString("AME_HOME") ?? "")/java_runtimes/\(runtimeName)"
            let error = JavaRuntimeExtractor.extractTarXZ(path,
                to: outPath,
                progress: totalProgress,
                fileProgress: fileProgress,
                fileCallback: { name in
                    let completedSize = ByteCountFormatter.string(fromByteCount: fileProgress.completedUnitCount, countStyle: .memory)
                    let totalSize = ByteCountFormatter.string(fromByteCount: fileProgress.totalUnitCount, countStyle: .memory)
                    nav?.progressText?.text = "(\(completedSize) / \(totalSize)) \(name)"
                    currentProgressView?.setValue(NSNumber(value: totalProgress.fractionCompleted), forKey: "fractionCompleted")
                },
                validate: { runtimePath in
                    return LauncherPrefManageJREViewController.validateRuntimeInfo(runtimePath)
                })
            url.stopAccessingSecurityScopedResource()

            if let error = error {
                showDialog(localize("Error"), error)
            }

            DispatchQueue.main.async {
                let vc = LauncherPrefManageJREViewController.currentInstance
                currentProgressView = nil

                if let vc = vc {
                    if (error != nil || totalProgress.isCancelled), let installing = vc.installingIndexPath {
                        vc.removeRuntime(at: installing)
                    } else if let installing = vc.installingIndexPath,
                              installing.section < self.sortedJavaVersions.count,
                              let entries = self.javaRuntimes[self.sortedJavaVersions[installing.section]],
                              installing.row < entries.count {
                        entries[installing.row].installing = false
                    }
                    vc.installingIndexPath = nil
                    vc.tableView.reloadData()
                }

                nav?.setInteractionEnabled(true, forDownloading: false)
                nav?.progressViewMain?.observedProgress = nil
                nav?.progressViewSub?.observedProgress = nil
                nav?.progressText?.text = ""
            }
        }
    }

    // MARK: Table view

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sortedJavaVersions.count
    }

    private func headerTitle(forSection section: Int) -> String {
        let version = sortedJavaVersions[section]
        switch version {
        case defaultJRE: return localize("preference.manage_runtime.header.default")
        case invalidJRE: return localize("preference.manage_runtime.header.invalid")
        default: return "Java \(version)"
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return headerTitle(forSection: section)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sortedJavaVersions[section] {
        case defaultJRE: return localize("preference.manage_runtime.footer.default")
        case 8: return localize("preference.manage_runtime.footer.java8")
        case 17: return localize("preference.manage_runtime.footer.java17")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return javaRuntimes[sortedJavaVersions[section]]?.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0: return cellForDefaultRow(tableView, at: indexPath)
        default: return cellForRuntimeRow(tableView, at: indexPath)
        }
    }

    private func cellForDefaultRow(_ tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: "DefaultCell") {
            cell = reused
        } else {
            cell = UITableViewCell(style: .value1, reuseIdentifier: "DefaultCell")
            cell.accessoryType = .disclosureIndicator
        }
        if let entries = javaRuntimes[defaultJRE], indexPath.row < entries.count {
            cell.textLabel?.text = localize(entries[indexPath.row].name)
        }
        var selected = "(null)"
        if indexPath.row < selectedRTTags.count,
           let defaults = selectedRuntimes.object(forKey: "0") as? NSDictionary,
           let value = defaults.object(forKey: selectedRTTags[indexPath.row]) {
            selected = "\(value)"
        }
        cell.detailTextLabel?.text = "Java \(selected)"
        return cell
    }

    private func cellForRuntimeRow(_ tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: "RTCell") {
            cell = reused
        } else {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: "RTCell")
        }
        let version = sortedJavaVersions[indexPath.section]
        let entry = javaRuntimes[version]![indexPath.row]
        let name = entry.name
        let isInternal = entry.isInternal
        let isInstalling = entry.installing
        if isInternal {
            cell.textLabel?.text = "[Internal] \(name)"
        } else {
            cell.textLabel?.text = name
        }

        if isInstalling {
            installingIndexPath = indexPath

            if currentProgressView == nil {
                if let progressClass = NSClassFromString("WFWorkflowProgressView") as? UIControl.Type {
                    let progressView = progressClass.init(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
                    progressView.setValue(view.tintColor, forKey: "resolvedTintColor")
                    progressView.addTarget(LauncherPrefManageJREViewController.self,
                                           action: #selector(LauncherPrefManageJREViewController.actionCancelImportRuntime),
                                           for: .primaryActionTriggered)
                    currentProgressView = progressView
                }
            }

            cell.accessoryView = currentProgressView
        } else {
            cell.accessoryView = nil
        }

        // Set checkmark; with internal runtime it's a bit tricky to check
        let selectedName = selectedRuntimes.object(forKey: String(version)) as? String
        if selectedName == name || (isInternal && selectedName == "internal") {
            cell.accessoryType = .checkmark
        } else {
            cell.accessoryType = .none
        }

        // Display size
        DispatchQueue.global().async { [weak self, weak cell] in
            let base = isInternal ? Bundle.main.bundlePath : (envString("AME_HOME") ?? "")
            let directory = "\(base)/java_runtimes/\(name)"
            let folderSize = jreAllocatedSize(ofDirectory: directory)
            DispatchQueue.main.async {
                guard let self = self else { return }
                let sizeText = ByteCountFormatter.string(fromByteCount: Int64(bitPattern: folderSize), countStyle: .memory)
                cell?.detailTextLabel?.text = "\(self.javaVersion(forPath: directory)) - \(sizeText)"
            }
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if indexPath.section == 0 {
            openPicker(tableView, at: indexPath, minVersion: indexPath.row == 1 ? 17 : 8)
            return
        } else if sortedJavaVersions[indexPath.section] == invalidJRE {
            // TODO: do something, like alert explaining that the runtime has missing files
            return
        }

        // Update preference
        let version = sortedJavaVersions[indexPath.section]
        let entry = javaRuntimes[version]![indexPath.row]
        if entry.isInternal {
            selectedRuntimes.setObject("internal", forKey: String(version) as NSString)
        } else {
            selectedRuntimes.setObject(entry.name, forKey: String(version) as NSString)
        }
        setPrefObject("java.java_homes", selectedRuntimes)

        // Update checkmark
        let runtimeCount = javaRuntimes[version]?.count ?? 0
        for i in 0..<runtimeCount {
            let cell = self.tableView.cellForRow(at: IndexPath(row: i, section: indexPath.section))
            if i == indexPath.row {
                cell?.accessoryType = .checkmark
            } else {
                cell?.accessoryType = .none
            }
        }
    }

    // MARK: Context Menu configuration

    private func openPicker(_ tableView: UITableView, at indexPath: IndexPath, minVersion minVer: Int) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }

        var menuItems: [UIMenuElement] = []
        for i in stride(from: 1, to: sortedJavaVersions.count, by: 1) {
            if sortedJavaVersions[i] < minVer || sortedJavaVersions[i] == invalidJRE {
                continue
            }
            let version = headerTitle(forSection: i)
            menuItems.append(UIAction(title: version, image: nil, identifier: nil) { [weak self, weak cell] _ in
                guard let self = self, i < self.sortedJavaVersions.count, indexPath.row < self.selectedRTTags.count else { return }
                cell?.detailTextLabel?.text = version
                let defaults = jreMutableDictionary(self.selectedRuntimes.object(forKey: "0"))
                defaults.setObject(String(self.sortedJavaVersions[i]), forKey: self.selectedRTTags[indexPath.row] as NSString)
                self.selectedRuntimes.setObject(defaults, forKey: "0" as NSString)
                setPrefObject("java.java_homes", self.selectedRuntimes)
            })
        }

        cell.detailTextLabel?.interactions = []

        if menuItems.isEmpty {
            menuItems.append(UIAction(title: localize("None"), image: nil, identifier: nil) { _ in })
        }

        currentMenu = UIMenu(title: cell.textLabel?.text ?? "", children: menuItems)
        let interaction = UIContextMenuInteraction(delegate: self)
        cell.detailTextLabel?.addInteraction(interaction)
        jrePresentMenu(of: interaction)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            return self?.currentMenu
        }
    }

    /// Private UIKit delegate hook (UIKit+hook.h declares _UIContextMenuStyle). Makes the menu a compact popup.
    @objc(_contextMenuInteraction:styleForMenuWithConfiguration:)
    func _contextMenuInteraction(_ interaction: UIContextMenuInteraction, styleForMenuWith configuration: UIContextMenuConfiguration) -> _UIContextMenuStyle? {
        let style = _UIContextMenuStyle.defaultStyle()
        style?.preferredLayout = 3 // _UIContextMenuLayoutCompactMenu
        return style
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle != .delete { return }

        guard let cell = self.tableView.cellForRow(at: indexPath) else { return }
        let title = localize("preference.title.confirm")
        let message = String(format: localize("preference.title.confirm.delete_runtime"), cell.textLabel?.text ?? "")
        let confirmAlert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        confirmAlert.popoverPresentationController?.sourceView = cell
        confirmAlert.popoverPresentationController?.sourceRect = cell.bounds
        let ok = UIAlertAction(title: localize("OK"), style: .destructive) { [weak self, weak cell] _ in
            guard let self = self else { return }
            let directory = "\(envString("AME_HOME") ?? "")/java_runtimes/\(cell?.textLabel?.text ?? "")"
            do {
                try FileManager.default.removeItem(atPath: directory)
                self.removeRuntime(at: indexPath)
                self.tableView.reloadData()
            } catch {
                showDialog(localize("Error"), error.localizedDescription)
            }
        }
        let cancel = UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil)
        confirmAlert.addAction(cancel)
        confirmAlert.addAction(ok)
        present(confirmAlert, animated: true)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        let version = sortedJavaVersions[indexPath.section]
        let entry = javaRuntimes[version]![indexPath.row]
        let isInstalling = entry.installing && jreProgressFraction() > 0.0
        if entry.isInternal || isInstalling {
            return .none
        } else {
            return .delete
        }
    }

    // MARK: Version parser

    private func javaVersion(forPath path: String) -> String {
        let releasePath = (path as NSString).appendingPathComponent("release")
        let content: String
        do {
            content = try String(contentsOfFile: releasePath, encoding: .utf8)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        // The Obj-C version indexed [1] / [0] blindly and crashed on a release file without JAVA_VERSION
        let afterKey = content.components(separatedBy: "JAVA_VERSION=\"")
        guard afterKey.count > 1 else {
            return "Error: JAVA_VERSION not found"
        }
        return afterKey[1].components(separatedBy: "\"")[0]
    }

    private func majorVersion(forFullVersion version: String) -> Int {
        if version.hasPrefix("1.8.0") {
            return 8
        } else if version.hasPrefix("Error: ") {
            return invalidJRE
        } else {
            return (version.components(separatedBy: ".")[0] as NSString).integerValue
        }
    }

    private func majorVersion(forPath path: String) -> Int {
        return majorVersion(forFullVersion: javaVersion(forPath: path))
    }

    func addRuntimePath(_ path: String, markInternal: Bool) {
        let majorVer = majorVersion(forPath: path)
        if javaRuntimes[majorVer] == nil {
            javaRuntimes[majorVer] = []
            sortedJavaVersions.append(majorVer)
            sortedJavaVersions.sort()
        }

        let file = (path as NSString).lastPathComponent
        let entry = JavaRuntimeEntry(name: file, isInternal: markInternal)
        if !markInternal {
            let installingDir = (path as NSString).appendingPathComponent(".installing")
            entry.installing = FileManager.default.fileExists(atPath: installingDir)
        }

        javaRuntimes[majorVer]?.append(entry)
    }

    private func removeRuntime(at indexPath: IndexPath) {
        let cell = tableView.cellForRow(at: indexPath)
        let version = sortedJavaVersions[indexPath.section]
        guard let entries = javaRuntimes[version], indexPath.row < entries.count else { return }
        let entry = entries[indexPath.row]

        javaRuntimes[version]?.removeAll { $0 === entry }
        if javaRuntimes[version]?.isEmpty ?? true {
            javaRuntimes.removeValue(forKey: version)
            selectedRuntimes.removeObject(forKey: String(version))
            sortedJavaVersions.removeAll { $0 == version }
        } else if cell?.accessoryType == .checkmark, let first = javaRuntimes[version]?.first {
            selectedRuntimes.setObject(first.name, forKey: String(version) as NSString)
        }

        setPrefObject("java.java_homes", selectedRuntimes)
    }

    private func listJRE(inPath path: String, markInternal: Bool) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(atPath: path)) ?? []
        for file in files {
            let rtPath = (path as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            manager.fileExists(atPath: rtPath, isDirectory: &isDir)
            if isDir.boolValue {
                addRuntimePath(rtPath, markInternal: markInternal)
            }
        }
    }

    // MARK: Runtime info (release file of an extracted runtime)

    private static func parseRuntimeInfo(_ path: String) -> [String: String] {
        let releaseFile = (path as NSString).appendingPathComponent("release")
        let content: String
        do {
            content = try String(contentsOfFile: releaseFile, encoding: .utf8)
        } catch {
            return ["Error": error.localizedDescription]
        }

        var dict: [String: String] = [:]
        for line in content.components(separatedBy: CharacterSet.newlines) where line.count > 0 {
            let keyValue = String(line.dropLast()).components(separatedBy: "=\"")
            if keyValue.count > 1 {
                dict[keyValue[0]] = keyValue[1]
            }
        }
        return dict
    }

    /// Called by the extractor (background queue) once ./release is written. nil = runtime is usable.
    fileprivate static func validateRuntimeInfo(_ path: String) -> String? {
        let dict = parseRuntimeInfo(path)

        if let error = dict["Error"] {
            return error
        } else if dict["OS_ARCH"] != "aarch64" {
            return "Wrong runtime architecture: \(dict["OS_ARCH"] ?? "(null)") (need aarch64)"
        } else if dict["OS_NAME"] != "Darwin" {
            return "Wrong runtime platform: \(dict["OS_NAME"] ?? "(null)") (need Darwin)"
        }

        DispatchQueue.main.async {
            currentInstance?.addRuntimePath(path, markInternal: false)
            currentInstance?.tableView.reloadData()
        }

        DispatchQueue.main.async {
            if let instance = currentInstance, let installing = instance.installingIndexPath {
                instance.tableView.scrollToRow(at: installing, at: .bottom, animated: true)
            }
        }
        return nil
    }
}
