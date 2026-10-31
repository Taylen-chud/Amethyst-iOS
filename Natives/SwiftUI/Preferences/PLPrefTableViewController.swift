import UIKit
import ObjectiveC

struct PrefItem {
    enum Kind {
        case none          // header rows
        case button        // was typeButton
        case childPane     // was typeChildPane
        case pickField     // was typePickField
        case textField     // was typeTextField
        case slider        // was typeSlider
        case toggle        // was typeSwitch
        case custom        // a CreateView block of the row's own (see customCreate)
    }

    var kind: Kind = .none
    var key: String = ""
    var title: String? = nil
    var icon: String? = nil
    var hasDetail = false
    var destructive = false
    var requestReload = false
    var showConfirmPrompt = false

    /// Called to decide if the row is usable. nil = always enabled.
    var enableCondition: (() -> Bool)? = nil

    // button
    var action: (() -> Void)? = nil

    // switch
    /// [valueWhenOff, valueWhenOn], stored instead of NO/YES
    var customSwitchValue: [String]? = nil
    var onToggle: ((Bool) -> Void)? = nil

    // slider
    var min = 0
    var max = 0

    // pick field
    var pickKeys: [String] = []
    var pickList: [String] = []
    var onPick: ((String) -> Void)? = nil

    // text field
    var placeholder: String? = nil
    var customClass: UITextField.Type? = nil

    // custom row: builds the cell itself, called as (cell, section, key, item) like the Obj-C CreateView blocks
    var customCreate: ((UITableViewCell, String, String, PrefItem) -> Void)? = nil

    // child pane
    var canDismissWithSwipe = false
    /// Builds the pane that is opened, was `@"class"` + `+new`
    var makeChild: (() -> UIViewController)? = nil

    // warnings (switch / slider / text field)
    var warnCondition: ((UIView) -> Bool)? = nil
    var warnKey: String? = nil

    init(kind: Kind = .none,
         key: String = "",
         title: String? = nil,
         icon: String? = nil,
         hasDetail: Bool = false,
         destructive: Bool = false,
         requestReload: Bool = false,
         showConfirmPrompt: Bool = false,
         enableCondition: (() -> Bool)? = nil,
         action: (() -> Void)? = nil,
         customSwitchValue: [String]? = nil,
         onToggle: ((Bool) -> Void)? = nil,
         min: Int = 0,
         max: Int = 0,
         pickKeys: [String] = [],
         pickList: [String] = [],
         onPick: ((String) -> Void)? = nil,
         placeholder: String? = nil,
         customClass: UITextField.Type? = nil,
         canDismissWithSwipe: Bool = false,
         makeChild: (() -> UIViewController)? = nil,
         customCreate: ((UITableViewCell, String, String, PrefItem) -> Void)? = nil,
         warnCondition: ((UIView) -> Bool)? = nil,
         warnKey: String? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.icon = icon
        self.hasDetail = hasDetail
        self.destructive = destructive
        self.requestReload = requestReload
        self.showConfirmPrompt = showConfirmPrompt
        self.enableCondition = enableCondition
        self.action = action
        self.customSwitchValue = customSwitchValue
        self.onToggle = onToggle
        self.min = min
        self.max = max
        self.pickKeys = pickKeys
        self.pickList = pickList
        self.onPick = onPick
        self.placeholder = placeholder
        self.customClass = customClass
        self.canDismissWithSwipe = canDismissWithSwipe
        self.makeChild = makeChild
        self.customCreate = customCreate
        self.warnCondition = warnCondition
        self.warnKey = warnKey
    }
}

typealias GetPreferenceBlock = (_ section: String, _ key: String) -> Any?
typealias SetPreferenceBlock = (_ section: String, _ key: String, _ value: Any?) -> Void

// MARK: - Value helpers (Obj-C `intValue` / `boolValue` semantics on whatever the prefs hold)

func prefInt(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return (string as NSString).integerValue }
    return 0
}

func prefBool(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String { return (string as NSString).boolValue }
    return false
}

// MARK: - Control <-> row link

/// Stored on the accessory view of a row (was objc_setAssociatedObject "section"/"key"/"item").
/// It only keeps the position, the row itself is looked up again when the control fires, so the
/// view never keeps the row's closures (and through them the controller) alive.
private final class PrefControlContext: NSObject {
    let sectionIndex: Int
    let row: Int
    let section: String
    let key: String

    init(sectionIndex: Int, row: Int, section: String, key: String) {
        self.sectionIndex = sectionIndex
        self.row = row
        self.section = section
        self.key = key
    }
}

private var prefControlContextKey: UInt8 = 0

// MARK: - Controller

/// Base class of every settings-like table (settings, game directory, profile editor, installers...).
@objc(PLPrefTableViewController)
@objcMembers
class PLPrefTableViewController: UITableViewController, UITextFieldDelegate, UIContextMenuInteractionDelegate {

    var getPreference: GetPreferenceBlock?
    var setPreference: SetPreferenceBlock?
    var prefSectionsVisible = false
    var hasDetail = false

    var prefSections: [String]?
    var prefSectionsVisibility: [Bool] = []
    var prefContents: [[PrefItem]] = []
    var prefDetailVisible = false

    private var currentMenu: UIMenu?
    private var helpBtn: UIBarButtonItem?

    init() {
        super.init(style: .plain)
    }

    override init(style: UITableView.Style) {
        super.init(style: style)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.keyboardDismissMode = .interactive
        if let sections = prefSections {
            prefSectionsVisibility = Array(repeating: prefSectionsVisible, count: sections.count)
        } else {
            // Display one single section if prefSections is unspecified
            prefSectionsVisibility = [true]
        }
    }

    func drawHelpButton() -> UIBarButtonItem {
        if helpBtn == nil {
            helpBtn = UIBarButtonItem(image: UIImage(systemName: "questionmark.circle"),
                                      style: .done,
                                      target: self,
                                      action: #selector(toggleDetailVisibility))
        }
        return helpBtn!
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Put navigation buttons back in place if we're first of the navigation controller
        if hasDetail && navigationController != nil {
            var items: [UIBarButtonItem] = []
            if let account = sidebarViewController?.drawAccountButton() {
                items.append(account)
            }
            items.append(drawHelpButton())
            navigationItem.rightBarButtonItems = items
        }

        // Scan for child pane cells and reload them
        var indexPaths: [IndexPath] = []
        for section in 0..<prefContents.count {
            guard section < prefSectionsVisibility.count, prefSectionsVisibility[section] else { continue }
            for row in 0..<prefContents[section].count where prefContents[section][row].kind == .childPane {
                indexPaths.append(IndexPath(row: row, section: section))
            }
        }
        tableView.reloadRows(at: indexPaths, with: .none)
    }

    // MARK: UITableView

    func toggleDetailVisibility() {
        prefDetailVisible.toggle()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return prefSectionsVisibility.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if prefSectionsVisibility[section] {
            return prefContents[section].count
        }
        return 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = prefContents[indexPath.section][indexPath.row]

        let cellID: String
        let cellStyle: UITableViewCell.CellStyle
        if item.kind == .childPane || item.kind == .pickField {
            cellID = "cellValue1"
            cellStyle = .value1
        } else {
            cellID = "cellSubtitle"
            cellStyle = .subtitle
        }

        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: cellID) {
            cell = reused
        } else {
            cell = UITableViewCell(style: cellStyle, reuseIdentifier: cellID)
            cell.textLabel?.adjustsFontSizeToFitWidth = true
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.lineBreakMode = .byWordWrapping
            cell.detailTextLabel?.numberOfLines = 0
            cell.detailTextLabel?.lineBreakMode = .byWordWrapping
        }
        // Reset cell properties, as it could be reused
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.textLabel?.textColor = nil
        cell.detailTextLabel?.text = nil

        var key = item.key
        if indexPath.row == 0, let sections = prefSections {
            key = sections[indexPath.section]
            cell.selectionStyle = .default
            cell.textLabel?.text = localize("preference.section.\(key)")
        } else {
            let section = prefSections?[indexPath.section] ?? ""
            configure(cell: cell, item: item, section: section, key: key)
            if let accessory = cell.accessoryView {
                let context = PrefControlContext(sectionIndex: indexPath.section, row: indexPath.row, section: section, key: key)
                objc_setAssociatedObject(accessory, &prefControlContextKey, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            cell.textLabel?.text = localize(item.title ?? "preference.title.\(key)")
        }

        // Set general properties
        cell.imageView?.tintColor = item.destructive ? UIColor.systemRed : nil
        cell.imageView?.image = item.icon.flatMap { UIImage(systemName: $0) }

        if cellStyle != .value1 {
            cell.detailTextLabel?.text = nil
            if item.hasDetail && prefDetailVisible {
                cell.detailTextLabel?.text = localize("preference.detail.\(key)")
            }
        }

        // Check if the row has an enable condition and call it if it does
        let enabled = item.enableCondition?() ?? true
        cell.isUserInteractionEnabled = enabled
        cell.textLabel?.isEnabled = enabled
        cell.detailTextLabel?.isEnabled = enabled
        (cell.accessoryView as? UIControl)?.isEnabled = enabled

        return cell
    }

    // MARK: Cell creation per row kind

    private func configure(cell: UITableViewCell, item: PrefItem, section: String, key: String) {
        switch item.kind {
        case .none:
            break

        case .button:
            cell.selectionStyle = .gray
            cell.textLabel?.textColor = item.destructive ? UIColor.systemRed : view.tintColor

        case .childPane:
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .gray
            cell.detailTextLabel?.text = getPreference?(section, key) as? String

        case .pickField:
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .gray
            cell.detailTextLabel?.text = getPreference?(section, key) as? String

        case .textField:
            configureTextField(cell: cell, section: section, key: key, item: item)

        case .custom:
            item.customCreate?(cell, section, key, item)

        case .slider:
            let frame = CGRect(x: 0, y: 0, width: cell.bounds.size.width / 2.1, height: cell.bounds.size.height)
            let slider = DBNumberedSlider(frame: frame)
            slider.addTarget(self, action: #selector(sliderMoved(_:)), for: .valueChanged)
            slider.autoresizingMask = [.flexibleWidth, .flexibleLeftMargin]
            slider.minimumValue = Float(item.min)
            slider.maximumValue = Float(item.max)
            slider.isContinuous = true
            slider.value = Float(prefInt(getPreference?(section, key)))
            cell.accessoryView = slider

        case .toggle:
            let toggle = UISwitch()
            let current = getPreference?(section, key)
            if let custom = item.customSwitchValue, custom.count > 1 {
                toggle.setOn((current as? String) == custom[1], animated: false)
            } else {
                toggle.setOn(prefBool(current), animated: false)
            }
            toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        }
    }

    /// Was the `typeTextField` block. Public so a custom row can build on it (the profile editor's version picker does).
    func configureTextField(cell: UITableViewCell, section: String, key: String, item: PrefItem) {
        let fieldClass: UITextField.Type = item.customClass ?? UITextField.self
        let frame = CGRect(x: 0, y: 0, width: cell.bounds.size.width / 2.1, height: cell.bounds.size.height)
        let field = fieldClass.init(frame: frame)
        field.addTarget(field, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
        field.adjustsFontSizeToFitWidth = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.autoresizingMask = [.flexibleWidth, .flexibleLeftMargin]
        field.delegate = self
        field.returnKeyType = .done
        field.textAlignment = .right
        field.placeholder = localize(item.placeholder ?? "preference.placeholder.\(key)")
        field.text = getPreference?(section, key) as? String
        cell.accessoryView = field
    }

    // MARK: Alerts and warnings

    func showAlert(on view: UIView, title: String?, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = view.bounds
        alert.addAction(UIAlertAction(title: localize("OK"), style: .cancel, handler: nil))
        present(alert, animated: true)
    }

    private func context(of view: UIView) -> PrefControlContext? {
        return objc_getAssociatedObject(view, &prefControlContextKey) as? PrefControlContext
    }

    private func item(for context: PrefControlContext) -> PrefItem? {
        guard context.sectionIndex < prefContents.count,
              context.row < prefContents[context.sectionIndex].count else { return nil }
        return prefContents[context.sectionIndex][context.row]
    }

    func checkWarn(_ view: UIView) {
        guard let ctx = context(of: view), let item = item(for: ctx) else { return }

        // Display warning if: warn condition is met and either one of these:
        // - does not have warnKey, always warn
        // - has warnKey and its value is YES, warn once and set it to NO
        guard let isWarnable = item.warnCondition, isWarnable(view) else { return }
        if let warnKey = item.warnKey {
            guard prefBool(getPreference?("warnings", warnKey)) else { return }
            setPreference?("warnings", warnKey, NSNumber(value: false))
        }

        let message = localize("preference.warn.\(item.key)")
        showAlert(on: view, title: localize("Warning"), message: message)
    }

    // MARK: Control event handlers

    func sliderMoved(_ sender: UISlider) {
        checkWarn(sender)
        guard let ctx = context(of: sender) else { return }

        sender.value = Float(Int(sender.value))
        setPreference?(ctx.section, ctx.key, NSNumber(value: sender.value))
    }

    func switchChanged(_ sender: UISwitch) {
        checkWarn(sender)
        guard let ctx = context(of: sender), let item = item(for: ctx) else { return }

        // Special switches may define custom value instead of NO/YES
        if let custom = item.customSwitchValue, custom.count > 1 {
            setPreference?(ctx.section, item.key, custom[sender.isOn ? 1 : 0])
        } else {
            setPreference?(ctx.section, item.key, NSNumber(value: sender.isOn))
        }

        item.onToggle?(sender.isOn)

        // Some settings may affect the availability of other settings
        // In this case, a switch may request to reload to apply user interaction change
        if item.requestReload {
            // TODO: only reload needed rows
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if indexPath.row == 0 && prefSections != nil {
            prefSectionsVisibility[indexPath.section].toggle()
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .fade)
            return
        }

        let item = prefContents[indexPath.section][indexPath.row]

        switch item.kind {
        case .button:
            invokeActionWithPrompt(at: indexPath)
            return
        case .childPane:
            openChildPane(at: indexPath)
            return
        case .pickField:
            openPicker(at: indexPath)
            return
        default:
            break
        }

        if realUIIdiom != .tv {
            return
        }

        // userInterfaceIdiom = tvOS
        if item.kind == .toggle, let toggle = tableView.cellForRow(at: indexPath)?.accessoryView as? UISwitch {
            toggle.isOn = !toggle.isOn
            toggle.sendActions(for: .valueChanged)
        }
    }

    // MARK: Row actions

    private func openChildPane(at indexPath: IndexPath) {
        let item = prefContents[indexPath.section][indexPath.row]
        guard let vc = item.makeChild?() else { return }
        if item.canDismissWithSwipe {
            navigationController?.pushViewController(vc, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: vc)
            nav.navigationBar.prefersLargeTitles = true
            nav.isModalInPresentation = true
            navigationController?.present(nav, animated: true)
        }
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

    private func openPicker(at indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        let item = prefContents[indexPath.section][indexPath.row]
        let sectionName = prefSections?[indexPath.section] ?? ""

        var message: String? = nil
        if item.hasDetail {
            message = localize("preference.detail.\(item.key)")
        }

        var menuItems: [UIAction] = []
        for (i, title) in item.pickList.enumerated() where i < item.pickKeys.count {
            let pickKey = item.pickKeys[i]
            let action = UIAction(title: title, image: nil, identifier: nil) { [weak self, weak cell] _ in
                cell?.detailTextLabel?.text = pickKey
                self?.setPreference?(sectionName, item.key, pickKey)
                item.onPick?(pickKey)
            }
            if cell.detailTextLabel?.text == pickKey {
                action.state = .on
            }
            menuItems.append(action)
        }

        currentMenu = UIMenu(title: message ?? "", children: menuItems)
        let interaction = UIContextMenuInteraction(delegate: self)
        cell.detailTextLabel?.interactions = [interaction]
        presentContextMenu(of: interaction)
    }

    private func invokeActionWithPrompt(at indexPath: IndexPath) {
        guard let view = tableView.cellForRow(at: indexPath) else { return }
        let item = prefContents[indexPath.section][indexPath.row]

        if item.showConfirmPrompt {
            let title = localize("preference.title.confirm")
            let message = localize("preference.title.confirm.\(item.key)")
            let confirmAlert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
            confirmAlert.popoverPresentationController?.sourceView = view
            confirmAlert.popoverPresentationController?.sourceRect = view.bounds
            let ok = UIAlertAction(title: localize("OK"), style: item.destructive ? .destructive : .default) { [weak self] _ in
                self?.invokeAction(at: indexPath)
            }
            let cancel = UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil)
            confirmAlert.addAction(cancel)
            confirmAlert.addAction(ok)
            present(confirmAlert, animated: true)
        } else {
            invokeAction(at: indexPath)
        }
    }

    private func invokeAction(at indexPath: IndexPath) {
        let item = prefContents[indexPath.section][indexPath.row]

        item.action?()

        guard let view = tableView.cellForRow(at: indexPath) else { return }
        let title = localize("preference.title.done.\(item.key)")
        showAlert(on: view, title: title, message: nil)
    }

    // MARK: UITextFieldDelegate

    func textFieldDidEndEditing(_ textField: UITextField) {
        checkWarn(textField)
        guard let ctx = context(of: textField) else { return }

        setPreference?(ctx.section, ctx.key, textField.text)
    }
}

/// Calls the private `-[UIContextMenuInteraction _presentMenuAtLocation:]` straight through its IMP,
/// so the call does not depend on how Swift renames that selector.
func presentContextMenu(of interaction: UIContextMenuInteraction) {
    let selector = NSSelectorFromString("_presentMenuAtLocation:")
    guard interaction.responds(to: selector), let imp = interaction.method(for: selector) else { return }
    typealias PresentFunc = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    unsafeBitCast(imp, to: PresentFunc.self)(interaction, selector, .zero)
}
