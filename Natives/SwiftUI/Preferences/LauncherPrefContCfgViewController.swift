import UIKit
import ObjectiveC

/// Stored on the text field of a mapping row (was objc_setAssociatedObject "gamepad_button" / "item").
/// `item` is the very dictionary that lives inside currentMappings, so editing it edits the mapping.
private final class GamepadMappingContext: NSObject {
    let button: String?
    let item: NSMutableDictionary

    init(button: String?, item: NSMutableDictionary) {
        self.button = button
        self.item = item
    }
}

private var gamepadMappingContextKey: UInt8 = 0

@objc(LauncherPrefContCfgViewController)
@objcMembers
class LauncherPrefContCfgViewController: UITableViewController, UITextFieldDelegate, UIPopoverPresentationControllerDelegate, UIPickerViewDataSource, UIPickerViewDelegate {

    private var currentFileName: String?
    private var currentMappings: NSMutableDictionary?
    private var keycodePlist: NSDictionary?
    private var editPickMapping: UIPickerView!
    private var activeTextField: UITextField?
    private var prefSections: [String] = []
    private var prefControllerTypes: [[String: String]] = []
    private let keyCodeMap = NSMutableArray()
    private let keyValueMap = NSMutableArray()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = localize("preference.title.default_gamepad_ctrl")

        if let plistPath = Bundle.main.path(forResource: "glfw_keycodes", ofType: "plist") {
            keycodePlist = NSDictionary(contentsOfFile: plistPath)
        }

        keyCodeMap.removeAllObjects()
        keyValueMap.removeAllObjects()
        initKeycodeTable(keyCodeMap, keyValueMap)

        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.keyboardDismissMode = .interactive
        tableView.sectionFooterHeight = 50

        loadGamepadConfigurationFile()
        prefControllerTypes = [["name": "xbox"], ["name": "playstation"]]

        prefSections = ["config_files", "game_mappings", "menu_mappings", "controller_style"]

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(actionMenuSave))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(exitButtonSelector))

        editPickMapping = UIPickerView()
        editPickMapping.delegate = self
        editPickMapping.dataSource = self
    }

    private func gamepadConfigPath() -> String {
        let name = (getPrefObject("control.default_gamepad_ctrl") as? String) ?? "(null)"
        return "\(envString("AME_HOME") ?? "")/controlmap/gamepads/\(name)"
    }

    func loadGamepadConfigurationFile() {
        currentMappings = parseJSONFromFile(gamepadConfigPath())
        let defaultCtrl = (getPrefObject("control.default_ctrl") as? String) ?? ""
        currentFileName = (defaultCtrl as NSString).deletingPathExtension
        let filterPredicate = NSPredicate { obj, _ in
            let name = (obj as? NSDictionary)?["name"] as? String
            return !(name?.hasPrefix("mouse_") ?? false)
        }
        (currentMappings?["mGameMappingList"] as? NSMutableArray)?.filter(using: filterPredicate)
        (currentMappings?["mMenuMappingList"] as? NSMutableArray)?.filter(using: filterPredicate)
    }

    // MARK: External UITableView functions

    override func numberOfSections(in tableView: UITableView) -> Int {
        return prefSections.count
    }

    private func prefContent(forIndex index: Int) -> [Any] {
        switch index {
        case 0: return [] // one single cell is defined in cellForRowAtIndexPath
        case 1: return (currentMappings?["mGameMappingList"] as? NSArray)?.map { $0 } ?? []
        case 2: return (currentMappings?["mMenuMappingList"] as? NSArray)?.map { $0 } ?? []
        case 3: return prefControllerTypes
        default: return []
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 1
        } else {
            return prefContent(forIndex: section).count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cellID = "cellValue\(indexPath.section)"
        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: cellID) {
            cell = reused
        } else {
            cell = UITableViewCell(style: .value1, reuseIdentifier: cellID)
            cell.detailTextLabel?.numberOfLines = 0
            cell.detailTextLabel?.lineBreakMode = .byWordWrapping
            cell.selectionStyle = .gray
        }

        if indexPath.section == 0 {
            cell.textLabel?.text = localize("controller_configurator.title.current")
            cell.accessoryType = .disclosureIndicator
            cell.detailTextLabel?.text = getPrefObject("control.default_gamepad_ctrl") as? String
        } else if indexPath.section == 1 || indexPath.section == 2 {
            let content = prefContent(forIndex: indexPath.section)
            guard indexPath.row < content.count, let item = content[indexPath.row] as? NSMutableDictionary else {
                return cell
            }
            let keycode = item["keycode"] as? NSNumber
            let name = item["name"] as? String
            let controllerType = (getPrefObject("control.controller_type") as? String) ?? "(null)"
            cell.textLabel?.text = localize("controller_configurator.\(controllerType).title.\(name ?? "(null)")")
            var view = cell.accessoryView as? PickTextField
            if view == nil {
                let field = PickTextField(frame: CGRect(x: 0, y: 0, width: cell.bounds.size.width / 2.1, height: cell.bounds.size.height))
                field.addTarget(field, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
                field.autocorrectionType = .no
                field.autocapitalizationType = .none
                field.autoresizingMask = [.flexibleWidth, .flexibleLeftMargin]
                field.delegate = self
                field.returnKeyType = .done
                field.tag = indexPath.section
                field.textAlignment = .right
                field.tintColor = UIColor.clear
                field.adjustsFontSizeToFitWidth = true
                field.inputView = editPickMapping
                field.setupDoneButton(target: self, action: #selector(closeTextField(_:)))
                cell.accessoryView = field
                view = field
            }
            if let keycode = keycode {
                let index = keyValueMap.index(of: keycode)
                view?.text = index != NSNotFound && index < keyCodeMap.count ? keyCodeMap[index] as? String : nil
            } else {
                view?.text = nil
            }
            if let view = view {
                objc_setAssociatedObject(view, &gamepadMappingContextKey,
                                         GamepadMappingContext(button: name, item: item),
                                         .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        } else if indexPath.section == 3 {
            let name = prefControllerTypes[indexPath.row]["name"] ?? ""
            cell.textLabel?.text = localize("controller_configurator.title.type.\(name)")
            if (getPrefObject("control.controller_type") as? String) == name {
                cell.accessoryType = .checkmark
            } else {
                cell.accessoryType = .none
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return localize("controller_configurator.section.\(prefSections[section])")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let key = "controller_configurator.section.footer.\(prefSections[section])"
        let footer = localize(key)
        return footer == key ? nil : footer
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)

        if indexPath.section == 0 {
            actionMenuLoad()
        } else if indexPath.section == 3 {
            setPrefObject("control.controller_type", prefControllerTypes[indexPath.row]["name"] ?? "")
            let sections = IndexSet(integersIn: 1..<4)
            self.tableView.reloadSections(sections, with: .none)
        }
        // 1 and 2 handle themselves with picker views.
    }

    // MARK: UITextField + UIPickerView

    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
        let label: UILabel
        if let reused = view as? UILabel {
            label = reused
        } else {
            label = UILabel()
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.textAlignment = .center
        }
        label.text = self.pickerView(pickerView, titleForRow: row, forComponent: component)

        return label
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        activeTextField?.text = keyCodeMap.object(at: row) as? String
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return keyCodeMap.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return keyCodeMap.object(at: row) as? String
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        activeTextField = textField
        let index = keyCodeMap.index(of: textField.text ?? "")
        if index != NSNotFound {
            editPickMapping.selectRow(index, inComponent: 0, animated: false)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // The context sits on the text field itself, it is the row's accessory view
        if let context = objc_getAssociatedObject(textField, &gamepadMappingContextKey) as? GamepadMappingContext {
            let text = textField.text ?? ""
            let keycode: Any?
            if !text.hasPrefix("SPECIALBTN") {
                keycode = keycodePlist?["GLFW_KEY_" + text]
            } else {
                keycode = keycodePlist?[text]
            }
            if let keycode = keycode {
                context.item.setObject(keycode, forKey: "keycode" as NSString)
            } else {
                context.item.removeObject(forKey: "keycode")
            }
        }
        activeTextField = nil
    }

    func closeTextField(_ sender: UIBarButtonItem) {
        activeTextField?.endEditing(true)
    }

    // MARK: UI

    func dismissModalViewController() {
        navigationController?.dismiss(animated: true)
    }

    func actionOpenFilePicker(_ handler: @escaping (String) -> Void) {
        let vc = FileListViewController()
        vc.listPath = "\(envString("AME_HOME") ?? "")/controlmap/gamepads"

        vc.whenItemSelected = handler
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = CGSize(width: 350, height: 250)

        let popoverController = vc.popoverPresentationController
        popoverController?.sourceView = tableView
        popoverController?.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: 0))
        popoverController?.delegate = self
        present(vc, animated: true)
    }

    func actionMenuLoad() {
        actionOpenFilePicker { [weak self] name in
            guard let self = self else { return }
            let currentFile = "\((getPrefObject("control.default_gamepad_ctrl") as? String) ?? "(null)").json"
            if currentFile != name {
                setPrefObject("control.default_gamepad_ctrl", "\(name).json")
                self.loadGamepadConfigurationFile()
                self.tableView.reloadData()
            }
        }
    }

    func actionMenuSaveWithExit(_ shouldExit: Bool) {
        let controller = UIAlertController(title: localize("custom_controls.control_menu.save"),
                                           message: shouldExit ? localize("custom_controls.control_menu.exit.warn") : "",
                                           preferredStyle: .alert)
        controller.addTextField { [weak self] textField in
            textField.placeholder = "Name"
            textField.text = self?.currentFileName
            textField.clearButtonMode = .whileEditing
            textField.borderStyle = .roundedRect
        }
        controller.addAction(UIAlertAction(title: localize("OK"), style: .default) { [weak self, weak controller] _ in
            guard let self = self, let field = controller?.textFields?.first else { return }
            let jsonData: Data
            do {
                jsonData = try JSONSerialization.data(withJSONObject: self.currentMappings ?? NSDictionary(), options: .prettyPrinted)
            } catch {
                showDialog(localize("custom_controls.control_menu.save.error.json"), error.localizedDescription)
                return
            }
            do {
                let path = "\(envString("AME_HOME") ?? "")/controlmap/gamepads/\(field.text ?? "").json"
                try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                showDialog(localize("custom_controls.control_menu.save.error.write"), error.localizedDescription)
                return
            }

            if shouldExit {
                self.dismissModalViewController()
            }

            setPrefObject("control.default_gamepad_ctrl", "\(field.text ?? "").json")
        })
        if shouldExit {
            controller.addAction(UIAlertAction(title: localize("custom_controls.control_menu.discard_changes"), style: .destructive) { [weak self] _ in
                self?.dismissModalViewController()
            })
        }
        controller.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
        present(controller, animated: true)
    }

    func actionMenuSave() {
        actionMenuSaveWithExit(false)
    }

    func exitButtonSelector() {
        let saved = parseJSONFromFile(gamepadConfigPath())
        if let current = currentMappings, let saved = saved, current.isEqual(saved) {
            dismissModalViewController()
        } else {
            actionMenuSaveWithExit(true)
        }
    }
}
