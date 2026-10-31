import UIKit

@objc(LauncherProfilesViewController)
@objcMembers
class LauncherProfilesViewController: UITableViewController {
    private enum Section: Int {
        case instances = 0
        case profiles
    }

    private var createButtonItem: UIBarButtonItem?

    init() {
        super.init(style: .plain)
        title = localize("Profiles")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The menu asks every page for its icon by selector
    func imageName() -> String {
        return "MenuProfiles"
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let createMenu = UIMenu(
            title: localize("profile.title.create"),
            image: nil,
            identifier: nil,
            options: .displayInline,
            children: [
                UIAction(title: "Vanilla", image: nil, identifier: UIAction.Identifier("vanilla")) { [weak self] _ in
                    self?.actionEditProfile(["name": "", "lastVersionId": "latest-release"] as NSDictionary)
                },
                // TODO (kept from the Obj-C version): OptiFine
                UIAction(title: "Fabric/Quilt", image: nil, identifier: UIAction.Identifier("fabric_or_quilt")) { [weak self] _ in
                    self?.actionCreateFabricProfile()
                },
                UIAction(title: "Forge", image: nil, identifier: UIAction.Identifier("forge")) { [weak self] _ in
                    self?.actionCreateForgeProfile()
                },
                UIAction(title: "Modpack", image: nil, identifier: UIAction.Identifier("modpack")) { [weak self] _ in
                    self?.actionCreateModpackProfile()
                }
            ])
        let item = UIBarButtonItem(barButtonSystemItem: .add, menu: createMenu)
        if #available(iOS 26.0, *) {
            item.sharesBackground = false
        }
        createButtonItem = item

        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.keyboardDismissMode = .interactive
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Put navigation buttons back in place
        var items: [UIBarButtonItem] = []
        if let account = sidebarViewController?.drawAccountButton() {
            items.append(account)
        }
        if let create = createButtonItem {
            items.append(create)
        }
        navigationItem.rightBarButtonItems = items

        // Pickup changes made in the profile editor and switching instance
        PLProfiles.updateCurrent()
        tableView.reloadData()
        (navigationController as? LauncherNavigationController)?.reloadProfileList()
    }

    func actionTogglePrefIsolation(_ sender: UISwitch) {
        if !sender.isOn {
            setPrefBool("internal.isolated", false)
        }
        toggleIsolatedPref(sender.isOn)
    }

    func actionCreateFabricProfile() {
        presentNavigatedViewController(FabricInstallViewController())
    }

    func actionCreateForgeProfile() {
        presentNavigatedViewController(ForgeInstallViewController())
    }

    func actionCreateModpackProfile() {
        presentNavigatedViewController(ModpackInstallViewController())
    }

    func actionEditProfile(_ profile: NSDictionary) {
        let vc = LauncherProfileEditorViewController()
        vc.profile = profile.mutableCopy() as? NSMutableDictionary
        presentNavigatedViewController(vc)
    }

    func presentNavigatedViewController(_ vc: UIViewController) {
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // MARK: Table view

    private var allProfiles: [Any] {
        return PLProfiles.current().profiles().allValues
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return localize("profile.section.instance")
        case 1: return localize("profile.section.profiles")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return PLProfiles.current().profiles().count
        default: return 0
        }
    }

    private func setupInstanceCell(_ cell: UITableViewCell, row: Int) {
        let demoLocked = getenv("DEMO_LOCK") != nil
        cell.isUserInteractionEnabled = !demoLocked
        if row == 0 {
            cell.imageView?.image = UIImage(systemName: "folder")
            cell.textLabel?.text = localize("preference.title.game_directory")
            cell.detailTextLabel?.text = demoLocked ? ".demo" : (getPrefObject("general.game_directory") as? String)
        } else {
            let imageName: String
            if #available(iOS 15.0, *) {
                imageName = "folder.badge.gearshape"
            } else {
                imageName = "folder.badge.gear"
            }
            cell.imageView?.image = UIImage(systemName: imageName)
            cell.textLabel?.text = localize("profile.title.separate_preference")
            cell.detailTextLabel?.text = localize("profile.detail.separate_preference")
            let toggle = UISwitch()
            toggle.setOn(getPrefBool("internal.isolated"), animated: false)
            toggle.addTarget(self, action: #selector(actionTogglePrefIsolation(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        }
    }

    private func setupProfileCell(_ cell: UITableViewCell, row: Int) {
        guard let profile = allProfiles[row] as? NSDictionary else { return }

        cell.textLabel?.text = profile["name"] as? String
        cell.detailTextLabel?.text = profile["lastVersionId"] as? String
        cell.imageView?.layer.magnificationFilter = .nearest

        let fallbackImage = UIImage(named: "DefaultProfile")?.iconResized(to: CGSize(width: 40, height: 40))
        let iconURL = (profile["icon"] as? String).flatMap { URL(string: $0) }
        cell.imageView?.setRemoteImage(iconURL, placeholder: fallbackImage)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let isInstance = indexPath.section == Section.instances.rawValue
        let cellID = isInstance ? "InstanceCell" : "ProfileCell"
        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: cellID) {
            cell = reused
            cell.imageView?.image = nil
            cell.isUserInteractionEnabled = true
            cell.accessoryView = nil
        } else {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: cellID)
            cell.accessoryType = .disclosureIndicator
            cell.detailTextLabel?.numberOfLines = 0
            cell.detailTextLabel?.lineBreakMode = .byWordWrapping
            if indexPath.section == Section.profiles.rawValue {
                cell.imageView?.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
                cell.imageView?.isSizeFixed = true
            }
        }

        if isInstance {
            setupInstanceCell(cell, row: indexPath.row)
        } else {
            setupProfileCell(cell, row: indexPath.row)
        }

        cell.textLabel?.isEnabled = cell.isUserInteractionEnabled
        cell.detailTextLabel?.isEnabled = cell.isUserInteractionEnabled
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)

        if indexPath.section == Section.instances.rawValue {
            if indexPath.row == 0 {
                navigationController?.pushViewController(LauncherPrefGameDirViewController(), animated: true)
            }
            return
        }

        if let profile = allProfiles[indexPath.row] as? NSDictionary {
            actionEditProfile(profile)
        }
    }

    // MARK: Editing

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle != .delete { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }

        let title = localize("preference.title.confirm")
        // reusing the delete runtime message
        let message = String(format: localize("preference.title.confirm.delete_runtime"), cell.textLabel?.text ?? "")
        let confirmAlert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        confirmAlert.popoverPresentationController?.sourceView = cell
        confirmAlert.popoverPresentationController?.sourceRect = cell.bounds
        let ok = UIAlertAction(title: localize("OK"), style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let name = cell.textLabel?.text ?? ""
            let profiles = PLProfiles.current().profiles()
            profiles?.removeObject(forKey: name)
            if PLProfiles.current().selectedProfileName() == name {
                // The one being deleted is the selected one, switch to the random one now
                if let first = profiles?.allKeys.first as? String {
                    PLProfiles.current().setSelectedProfileName(first)
                }
                (self.navigationController as? LauncherNavigationController)?.reloadProfileList()
            } else {
                PLProfiles.current().save()
            }
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
        let cancel = UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil)
        confirmAlert.addAction(cancel)
        confirmAlert.addAction(ok)
        present(confirmAlert, animated: true)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        if indexPath.section == Section.instances.rawValue || PLProfiles.current().profiles().count == 1 {
            return .none
        }
        return .delete
    }
}
