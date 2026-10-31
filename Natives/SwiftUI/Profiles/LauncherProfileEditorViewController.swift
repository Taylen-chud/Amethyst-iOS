import UIKit

/// `-[NSArray indexOfObject:]` stored into an Obj-C `int`: NSNotFound (NSIntegerMax) truncates to -1.
private func versionIndex(of object: Any?, in list: [Any]) -> Int32 {
    guard let object = object else { return -1 }
    let index = (list as NSArray).index(of: object)
    return Int32(truncatingIfNeeded: index)
}

private let versionTypes = ["installed", "release", "snapshot", "old_beta", "old_alpha"]

@objc(LauncherProfileEditorViewController)
@objcMembers
class LauncherProfileEditorViewController: PLPrefTableViewController, UIPickerViewDataSource, UIPickerViewDelegate {
    var profile: NSMutableDictionary!

    private var oldName = ""

    private var versionList: [Any]?
    private var versionTextField: PickTextField?
    private var versionTypeControl: UISegmentedControl!
    private var versionPickerView: UIPickerView!
    private var versionPickerToolbar: UIToolbar!
    private var versionSelectedAt: Int32 = 0

    override func viewDidLoad() {
        // Setup navigation bar & appearance
        title = localize("Edit profile")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(actionDone))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(actionClose))
        navigationController?.isModalInPresentation = true
        prefSectionsVisible = true

        // Setup preference getter and setter
        getPreference = { [weak self] section, key in
            return self?.profileValue(section: section, key: key)
        }
        setPreference = { [weak self] section, key, value in
            guard let self = self else { return }
            let string = value as? String
            if string == "(default)" && self.isPickField(section: section, key: key) {
                self.profile.removeObject(forKey: key)
            } else if let string = string {
                self.profile[key] = string
            }
        }

        // Obtain all the lists
        oldName = profileValue(section: "", key: "name") ?? ""
        if oldName.isEmpty {
            setPreference?("", "name", "New Profile")
        }
        let rendererKeys = getRendererKeys(true) as? [String] ?? []
        let rendererList = getRendererNames(true) as? [String] ?? []
        let ameHome = envString("AME_HOME") ?? ""
        let touchControlList = listFiles(atPath: "\(ameHome)/controlmap")
        let gamepadControlList = listFiles(atPath: "\(ameHome)/controlmap/gamepads")
        var javaList = ((getPrefObject("java.java_homes") as? NSDictionary)?.allKeys as? [String] ?? [])
            .sorted { $0.compare($1) == .orderedAscending }
        if !javaList.isEmpty {
            javaList[0] = "(default)"
        }

        // Setup version picker
        setupVersionPicker()
        let typeVersionPicker: (UITableViewCell, String, String, PrefItem) -> Void = { [weak self] cell, section, key, item in
            guard let self = self else { return }
            self.configureTextField(cell: cell, section: section, key: key, item: item)
            guard let textField = cell.accessoryView as? PickTextField else { return }
            self.versionTextField = textField
            textField.inputAccessoryView = self.versionPickerToolbar
            textField.inputView = self.versionPickerView
            // Auto pick version type
            if self.versionList != nil { return }
            let versionName = textField.text ?? ""
            if MinecraftResourceUtils.findVersion(versionName, inList: localVersionList as? [Any]) != nil {
                self.versionTypeControl.selectedSegmentIndex = 0
            } else if let selected = MinecraftResourceUtils.findVersion(versionName, inList: remoteVersionList as? [Any]) as? NSDictionary {
                let type = selected["type"] as? String ?? ""
                self.versionTypeControl.selectedSegmentIndex = versionTypes.firstIndex(of: type) ?? UISegmentedControl.noSegment
            } else {
                // Version not found
                self.versionTypeControl.selectedSegmentIndex = 0
            }
            self.versionSelectedAt = -1
            self.changeVersionType(nil)
        }

        prefContents = [
            [
                // General settings
                PrefItem(kind: .textField,
                         key: "name",
                         title: "preference.profile.title.name",
                         icon: "tag",
                         placeholder: oldName),
                PrefItem(kind: .custom,
                         key: "lastVersionId",
                         title: "preference.profile.title.version",
                         icon: "archivebox",
                         placeholder: profileValue(section: "", key: "lastVersionId"),
                         customClass: PickTextField.self,
                         customCreate: typeVersionPicker),
                PrefItem(kind: .textField,
                         key: "gameDir",
                         title: "preference.title.game_directory",
                         icon: "folder",
                         placeholder: ". -> /Documents/instances/\(getPrefObject("general.game_directory") as? String ?? "")"),
                // Video and renderer settings
                PrefItem(kind: .pickField,
                         key: "renderer",
                         icon: "cpu",
                         pickKeys: rendererKeys,
                         pickList: rendererList),
                // Control settings
                PrefItem(kind: .pickField,
                         key: "defaultTouchCtrl",
                         title: "preference.profile.title.default_touch_control",
                         icon: "hand.tap",
                         pickKeys: touchControlList,
                         pickList: touchControlList),
                PrefItem(kind: .pickField,
                         key: "defaultGamepadCtrl",
                         title: "preference.profile.title.default_gamepad_control",
                         icon: "gamecontroller",
                         pickKeys: gamepadControlList,
                         pickList: gamepadControlList),
                // Java tweaks
                PrefItem(kind: .pickField,
                         key: "javaVersion",
                         title: "preference.manage_runtime.header.default",
                         icon: "cube",
                         pickKeys: javaList,
                         pickList: javaList),
                PrefItem(kind: .textField,
                         key: "javaArgs",
                         title: "preference.title.java_args",
                         icon: "slider.vertical.3",
                         placeholder: "(default)")
            ]
        ]

        super.viewDidLoad()
    }

    /// Value of a profile key, or "(default)" for an empty pick field
    private func profileValue(section: String, key: String) -> String? {
        let value = profile?[key] as? String
        if (value?.isEmpty == false) || !isPickField(section: section, key: key) {
            return value
        } else {
            return "(default)"
        }
    }

    func actionClose() {
        navigationController?.dismiss(animated: true)
    }

    /// `-[UIResponder _firstResponder]` is private, fall back to a search when it is not there
    private func currentFirstResponderTextField() -> UITextField? {
        let selector = NSSelectorFromString("_firstResponder")
        if responds(to: selector), let result = perform(selector)?.takeUnretainedValue() as? UITextField {
            return result
        }
        func find(in view: UIView) -> UITextField? {
            if let field = view as? UITextField, field.isFirstResponder { return field }
            for subview in view.subviews {
                if let found = find(in: subview) { return found }
            }
            return nil
        }
        return find(in: tableView)
    }

    func actionDone() {
        // We might be saving without ending editing, so make sure textFieldDidEndEditing is always called
        if let currentTextField = currentFirstResponderTextField(), currentTextField.isDescendant(of: tableView) {
            textFieldDidEndEditing(currentTextField)
        }

        let currentName = profile["name"] as? String ?? ""
        if currentName.isEmpty && !oldName.isEmpty {
            // Return to its old name
            profile["name"] = oldName
        }

        let profiles = PLProfiles.current().profiles()
        let newName = profile["name"] as? String ?? ""
        if oldName == newName {
            // Not a rename, directly create/replace
            profiles?.setObject(profile as Any, forKey: oldName as NSString)
        } else if profiles?.object(forKey: newName) == nil {
            // A rename, remove then re-add to update its key name
            if !oldName.isEmpty {
                profiles?.removeObject(forKey: oldName)
            }
            profiles?.setObject(profile as Any, forKey: newName as NSString)
            // Update selected name
            if PLProfiles.current().selectedProfileName() == oldName {
                PLProfiles.current().setSelectedProfileName(newName)
            }
        } else {
            // Cancel rename since a profile with the same name already exists
            showDialog(localize("Error"), localize("profile.error.name_exists"))
            // Skip dismissing this view controller
            return
        }

        PLProfiles.current().save()
        actionClose()

        // Call LauncherProfilesViewController's viewWillAppear
        if let split = presentingViewController as? UISplitViewController,
           split.viewControllers.count > 1,
           let navVC = split.viewControllers[1] as? UINavigationController {
            navVC.viewControllers.first?.viewWillAppear(false)
        }
    }

    private func isPickField(section: String, key: String) -> Bool {
        guard let first = prefContents.first else { return false }
        return first.first(where: { $0.key == key })?.kind == .pickField
    }

    private func listFiles(atPath path: String) -> [String] {
        var files = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".json") }
        files.insert("(default)", at: 0)
        return files
    }

    // MARK: Version picker

    private func setupVersionPicker() {
        versionPickerView = UIPickerView()
        versionPickerView.delegate = self
        versionPickerView.dataSource = self
        versionPickerToolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        versionTypeControl = UISegmentedControl(items: [
            localize("Installed"),
            localize("Releases"),
            localize("Snapshot"),
            localize("Old-beta"),
            localize("Old-alpha")
        ])
        versionTypeControl.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        versionTypeControl.autoresizingMask = .flexibleWidth
        versionTypeControl.addTarget(self, action: #selector(changeVersionType(_:)), for: .valueChanged)
        // here we go some random private apis I found
        let labelsSelector = NSSelectorFromString("_uiktest_labelsWithState:")
        if versionTypeControl.responds(to: labelsSelector),
           let labels = versionTypeControl.perform(labelsSelector, with: nil)?.takeUnretainedValue() as? [UILabel] {
            for label in labels {
                label.numberOfLines = 0
            }
        }
        versionPickerToolbar.addSubview(versionTypeControl)
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        guard let list = versionList, !list.isEmpty else {
            versionTextField?.text = ""
            return
        }
        versionSelectedAt = Int32(truncatingIfNeeded: row)
        versionTextField?.text = self.pickerView(pickerView, titleForRow: row, forComponent: component)
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return versionList?.count ?? 0
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        guard let list = versionList, row >= 0, row < list.count else { return nil }
        let object = list[row]
        if let string = object as? String {
            return string
        } else {
            return (object as AnyObject).value(forKey: "id") as? String
        }
    }

    func versionClosePicker() {
        versionTextField?.endEditing(true)
        pickerView(versionPickerView, didSelectRow: versionPickerView.selectedRow(inComponent: 0), inComponent: 0)
    }

    func changeVersionType(_ sender: UISegmentedControl?) {
        var newVersionList: [Any] = versionList ?? []
        if sender != nil || versionList == nil {
            if versionTypeControl.selectedSegmentIndex == 0 {
                // installed
                newVersionList = localVersionList as? [Any] ?? []
            } else {
                let type = versionTypes[versionTypeControl.selectedSegmentIndex]
                newVersionList = (remoteVersionList as NSArray?)?.filtered(using: NSPredicate(format: "(type == %@)", type)) ?? []
            }
        }

        if versionSelectedAt == -1 {
            let selected = MinecraftResourceUtils.findVersion(versionTextField?.text ?? "", inList: newVersionList)
            versionSelectedAt = versionIndex(of: selected, in: newVersionList)
        } else {
            // Find the most matching version for this type
            var lastSelected: Any? = nil
            if let list = versionList, versionSelectedAt >= 0, list.count > Int(versionSelectedAt) {
                lastSelected = list[Int(versionSelectedAt)]
            }
            if let lastSelected = lastSelected {
                let nearest = MinecraftResourceUtils.findNearestVersion(lastSelected as? NSObject, expectedType: Int32(versionTypeControl.selectedSegmentIndex))
                if let nearest = nearest {
                    versionSelectedAt = versionIndex(of: nearest, in: newVersionList)
                }
            }
            // Get back the currently selected in case none matching version found
            // (`MIN(abs(int), NSUInteger - 1)`: with an empty list `count - 1` wraps around, so abs() wins)
            let absolute = Int(abs(versionSelectedAt))
            versionSelectedAt = newVersionList.isEmpty ? Int32(truncatingIfNeeded: absolute) : Int32(truncatingIfNeeded: min(absolute, newVersionList.count - 1))
        }

        versionList = newVersionList
        versionPickerView.reloadAllComponents()
        if versionSelectedAt != -1 {
            versionPickerView.selectRow(Int(versionSelectedAt), inComponent: 0, animated: false)
            pickerView(versionPickerView, didSelectRow: Int(versionSelectedAt), inComponent: 0)
        }
    }
}
