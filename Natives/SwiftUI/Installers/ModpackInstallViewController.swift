import UIKit

@objc(ModpackInstallViewController)
@objcMembers
class ModpackInstallViewController: UITableViewController, UISearchResultsUpdating, UIContextMenuInteractionDelegate {
    private var searchController: UISearchController!
    private var currentMenu: UIMenu?
    private var list: NSMutableArray?
    private var filters = NSMutableDictionary()
    private var modrinth = ModrinthAPI()

    override func viewDidLoad() {
        super.viewDidLoad()

        searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        modrinth = ModrinthAPI()
        filters = [
            "isModpack": NSNumber(value: true),
            "name": " "
            // mcVersion
        ]
        updateSearchResults()
    }

    func loadSearchResults(withPrevList prevList: Bool) {
        let name = searchController.searchBar.text ?? ""
        if !prevList && (filters["name"] as? String) == name {
            return
        }

        switchToLoadingState()
        let previous = prevList ? list : nil
        DispatchQueue.global().async { [self] in
            filters["name"] = name
            // -searchModWithFilters:previousPageResult:
            let result = objcSend(modrinth, "searchModWithFilters:previousPageResult:", filters, previous) as? NSMutableArray
            list = result
            DispatchQueue.main.async { [self] in
                if list != nil {
                    switchToReadyState()
                    tableView.reloadData()
                } else {
                    showDialog(localize("Error"), modrinth.lastError?.localizedDescription ?? "")
                    actionClose()
                }
            }
        }
    }

    func updateSearchResults() {
        loadSearchResults(withPrevList: false)
    }

    func updateSearchResults(for searchController: UISearchController) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateSearchResults as () -> Void), object: nil)
        perform(#selector(updateSearchResults as () -> Void), with: nil, afterDelay: 0.5)
    }

    func actionClose() {
        navigationController?.dismiss(animated: true)
    }

    func switchToLoadingState() {
        let indicator = UIActivityIndicatorView(style: .medium)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: indicator)
        indicator.startAnimating()
        navigationController?.isModalInPresentation = true
        tableView.allowsSelection = false
    }

    func switchToReadyState() {
        (navigationItem.rightBarButtonItem?.customView as? UIActivityIndicatorView)?.stopAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(actionClose))
        navigationController?.isModalInPresentation = false
        tableView.allowsSelection = true
    }

    // MARK: UIContextMenu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            return self?.currentMenu
        }
    }

    /// Private UIKit delegate hook, makes the menu a compact popup
    @objc(_contextMenuInteraction:styleForMenuWithConfiguration:)
    func _contextMenuInteraction(_ interaction: UIContextMenuInteraction, styleForMenuWith configuration: UIContextMenuConfiguration) -> _UIContextMenuStyle? {
        let style = _UIContextMenuStyle.defaultStyle()
        style?.preferredLayout = 3 // _UIContextMenuLayoutCompactMenu
        return style
    }

    // MARK: UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return list?.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: "cell") {
            cell = reused
        } else {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
            cell.imageView?.contentMode = .scaleToFill
            cell.imageView?.clipsToBounds = true
        }

        let item = list?[indexPath.row] as? NSDictionary
        cell.textLabel?.text = item?["title"] as? String
        cell.detailTextLabel?.text = item?["description"] as? String
        let fallbackImage = UIImage(named: "DefaultProfile")
        let imageURL = (item?["imageUrl"] as? String).flatMap { URL(string: $0) }
        cell.imageView?.setRemoteImage(imageURL, placeholder: fallbackImage)

        if !modrinth.reachedLastPage && indexPath.row == (list?.count ?? 0) - 1 {
            loadSearchResults(withPrevList: true)
        }

        return cell
    }

    func showDetails(_ details: NSDictionary, at indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }

        var menuItems: [UIAction] = []
        let versionNames = details["versionNames"] as? [String] ?? []
        let mcVersionNames = details["mcVersionNames"] as? [String] ?? []
        for (i, name) in versionNames.enumerated() {
            var nameWithVersion = name
            let mcVersion = i < mcVersionNames.count ? mcVersionNames[i] : ""
            if !name.hasSuffix(mcVersion) {
                nameWithVersion = "\(name) - \(mcVersion)"
            }
            menuItems.append(UIAction(title: nameWithVersion, image: nil, identifier: nil) { [weak self, weak cell] _ in
                guard let self = self else { return }
                self.actionClose()
                let tmpIconPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("icon.png")
                if let image = cell?.imageView?.image {
                    try? image.iconResized(to: CGSize(width: 40, height: 40)).pngData()?.write(to: URL(fileURLWithPath: tmpIconPath), options: .atomic)
                }
                // -installModpackFromDetail:atIndex:
                objcSendObjectAndIndex(self.modrinth, "installModpackFromDetail:atIndex:", self.list?[indexPath.row] as AnyObject?, i)
            })
        }

        currentMenu = UIMenu(title: "", children: menuItems)
        let interaction = UIContextMenuInteraction(delegate: self)
        cell.detailTextLabel?.interactions = [interaction]
        presentContextMenu(of: interaction)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = list?[indexPath.row] as? NSDictionary else { return }
        if prefBool(item["versionDetailsLoaded"]) {
            showDetails(item, at: indexPath)
            return
        }
        tableView.deselectRow(at: indexPath, animated: false)
        switchToLoadingState()
        DispatchQueue.global().async { [self] in
            // -loadDetailsOfMod:
            objcSend(modrinth, "loadDetailsOfMod:", list?[indexPath.row] as AnyObject?)
            DispatchQueue.main.async { [self] in
                switchToReadyState()
                if prefBool(item["versionDetailsLoaded"]) {
                    showDetails(item, at: indexPath)
                } else {
                    showDialog(localize("Error"), modrinth.lastError?.localizedDescription ?? "")
                }
            }
        }
    }
}
