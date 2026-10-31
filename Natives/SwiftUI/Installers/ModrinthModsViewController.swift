import UIKit
import ObjectiveC

private func mrLookup(_ target: AnyObject, _ selector: String) -> (imp: IMP, sel: Selector)? {
    let sel = NSSelectorFromString(selector)
    guard let cls = object_getClass(target), let method = class_getInstanceMethod(cls, sel) else {
        NSLog("[ModrinthMods] %@ does not respond to %@", String(describing: target), selector)
        return nil
    }
    return (method_getImplementation(method), sel)
}

/// `[target selector:a b:b ...]` for up to four object arguments, returns an object
@discardableResult
private func mrCall(_ target: AnyObject, _ selector: String, _ args: AnyObject?...) -> AnyObject? {
    guard let found = mrLookup(target, selector) else { return nil }
    let imp = found.imp
    let sel = found.sel
    switch args.count {
    case 0:
        typealias Function0 = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(imp, to: Function0.self)(target, sel)?.takeUnretainedValue()
    case 1:
        typealias Function1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(imp, to: Function1.self)(target, sel, args[0])?.takeUnretainedValue()
    case 2:
        typealias Function2 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(imp, to: Function2.self)(target, sel, args[0], args[1])?.takeUnretainedValue()
    case 3:
        typealias Function3 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(imp, to: Function3.self)(target, sel, args[0], args[1], args[2])?.takeUnretainedValue()
    default:
        typealias Function4 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(imp, to: Function4.self)(target, sel, args[0], args[1], args[2], args[3])?.takeUnretainedValue()
    }
}

/// Same for methods that return nothing
private func mrCallVoid(_ target: AnyObject, _ selector: String, _ args: AnyObject?...) {
    guard let found = mrLookup(target, selector) else { return }
    let imp = found.imp
    let sel = found.sel
    switch args.count {
    case 0:
        typealias VoidFunction0 = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(imp, to: VoidFunction0.self)(target, sel)
    case 1:
        typealias VoidFunction1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(imp, to: VoidFunction1.self)(target, sel, args[0])
    default:
        typealias VoidFunction2 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        unsafeBitCast(imp, to: VoidFunction2.self)(target, sel, args[0], args[1])
    }
}

/// `+[InstalledModsManager entriesInDirectory:identify:error:]`
private func mrInstalledEntries(directory: String, identify: Bool, error: inout Error?) -> NSArray? {
    let manager: AnyObject = InstalledModsManager.self
    guard let found = mrLookup(manager, "entriesInDirectory:identify:error:") else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, Bool, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Unmanaged<AnyObject>?
    var errorSlot: Unmanaged<NSError>? = nil
    let result = unsafeBitCast(found.imp, to: Function.self)(manager, found.sel, directory as NSString, identify, &errorSlot)?.takeUnretainedValue()
    error = errorSlot?.takeUnretainedValue()
    return result as? NSArray
}

/// `+[InstalledModsManager setEntry:enabled:directory:error:]`
private func mrSetEntry(_ entry: NSDictionary, enabled: Bool, directory: String, error: inout Error?) {
    let manager: AnyObject = InstalledModsManager.self
    guard let found = mrLookup(manager, "setEntry:enabled:directory:error:") else { return }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, Bool, AnyObject?, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
    var errorSlot: Unmanaged<NSError>? = nil
    _ = unsafeBitCast(found.imp, to: Function.self)(manager, found.sel, entry, enabled, directory as NSString, &errorSlot)
    error = errorSlot?.takeUnretainedValue()
}

/// `+[InstalledModsManager removeEntry:directory:error:]`
private func mrRemoveEntry(_ entry: NSDictionary, directory: String, error: inout Error?) {
    let manager: AnyObject = InstalledModsManager.self
    guard let found = mrLookup(manager, "removeEntry:directory:error:") else { return }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
    var errorSlot: Unmanaged<NSError>? = nil
    _ = unsafeBitCast(found.imp, to: Function.self)(manager, found.sel, entry, directory as NSString, &errorSlot)
    error = errorSlot?.takeUnretainedValue()
}

// MARK: - Small value helpers (Obj-C messaging-nil semantics)

private func mrBool(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    return (value as? Bool) ?? false
}

/// `[a isEqual:b]` where a nil receiver or argument gives NO
private func mrEqual(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a, let b = b, let lhs = (a as AnyObject) as? NSObject else { return false }
    return lhs.isEqual(b as AnyObject)
}

private func mrString(_ value: Any?) -> String? {
    return value as? String
}

private func mrDict(_ value: Any?) -> [String: Any]? {
    return value as? [String: Any]
}

private func mrDescribe(_ value: Any?) -> String {
    guard let value = value else { return "(null)" }
    return String(describing: value as AnyObject)
}

private func mrLoaderTitle(_ loader: String?) -> String {
    let names = ["fabric": "Fabric", "quilt": "Quilt", "forge": "Forge", "neoforge": "NeoForge", "liteloader": "LiteLoader", "rift": "Rift"]
    return (loader.flatMap { names[$0] }) ?? localize("mods.filter.any")
}

private func mrContentAPI(_ provider: String?) -> ModpackAPI {
    return provider == "curseforge" ? CurseForgeAPI() : ModrinthAPI()
}

private func mrProviderTitle(_ provider: String?) -> String {
    return provider == "curseforge" ? "CurseForge" : "Modrinth"
}

private func mrContentFolder(_ type: String?) -> String {
    let folders = ["mod": "mods", "resourcepack": "resourcepacks", "shader": "shaderpacks"]
    return (type.flatMap { folders[$0] }) ?? "mods"
}

private func mrContentType(forFilters filters: [String: Any]) -> String? {
    let filtersClass: AnyObject = ModrinthSearchFilters.self
    return mrCall(filtersClass, "contentTypeForFilters:", filters as NSDictionary) as? String
}

private func mrFilterSummary(_ filters: [String: Any]) -> String {
    let version = mrString(filters["mcVersion"]) ?? ""
    let game = version.count > 0 ? version : localize("mods.filter.any")
    if mrContentType(forFilters: filters) != "mod" {
        return "Minecraft " + game
    }
    return String(format: "Minecraft %@ · %@", game, mrLoaderTitle(mrString(filters["loader"])))
}

private func mrCategoryTitle(_ category: String) -> String {
    let key = "mods.category." + category
    let title = localize(key)
    return title == key ? category.replacingOccurrences(of: "-", with: " ").capitalized : title
}

private func mrCategorySymbol(_ category: String) -> String {
    let symbols = ["adventure": "safari", "cursed": "ant", "decoration": "house", "economy": "dollarsign.circle", "equipment": "shield", "food": "leaf", "game-mechanics": "slider.horizontal.3", "library": "books.vertical", "magic": "wand.and.stars", "management": "server.rack", "minigame": "flag", "mobs": "pawprint", "optimization": "bolt", "social": "person.2", "storage": "archivebox", "technology": "cpu", "transportation": "tram", "utility": "wrench.and.screwdriver", "worldgen": "globe", "combat": "shield", "modded": "puzzlepiece", "realistic": "camera", "simplistic": "square", "themed": "paintpalette", "tweaks": "slider.horizontal.3", "vanilla-like": "leaf", "cartoon": "pencil", "fantasy": "wand.and.stars", "semi-realistic": "camera.filters"]
    return symbols[category] ?? "tag"
}

/// Current profile root, selected profile and its game directory, as the Obj-C code derived them
private struct MRProfileContext {
    let profiles: PLProfiles
    let root: String?
    let profile: NSDictionary
    let name: String?
    let gameDir: String

    init() {
        profiles = PLProfiles.current()
        profile = (profiles.selectedProfile() as NSDictionary?) ?? NSDictionary()
        root = profiles.profilePath.map { ($0 as NSString).deletingLastPathComponent }
        name = profiles.selectedProfileName()
        if let dir = profile["gameDir"] as? String, dir.count > 0 {
            gameDir = dir
        } else {
            gameDir = "."
        }
    }
}

private func mrLatestVersions() -> NSDictionary {
    return (getPrefObject("internal.latest_version") as? NSDictionary) ?? NSDictionary()
}

private func mrDefaults(profile: NSDictionary, root: String?, contentType: String) -> [String: Any] {
    let filtersClass: AnyObject = ModrinthSearchFilters.self
    let result = mrCall(filtersClass, "defaultsForProfile:instanceRoot:latestVersions:contentType:",
                        profile, root.map { $0 as NSString }, mrLatestVersions(), contentType as NSString)
    return (result as? [String: Any]) ?? [:]
}

// MARK: - Icon view

private let modrinthIconCache = NSCache<NSURL, UIImage>()

/// Was a UIImageView with a shared AFImageDownloader that also accepted webp/avif
private final class ModrinthIconView: UIImageView {
    private var downloadTask: URLSessionDataTask?

    func cancelImageDownloadTask() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    func setImage(with url: URL, placeholder: UIImage?) {
        cancelImageDownloadTask()
        if let cached = modrinthIconCache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        image = placeholder
        var task: URLSessionDataTask?
        task = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            guard let data = data, let loaded = UIImage(data: data) else { return }
            modrinthIconCache.setObject(loaded, forKey: url as NSURL)
            DispatchQueue.main.async {
                guard let self = self, self.downloadTask === task else { return }
                self.image = loaded
                self.downloadTask = nil
            }
        }
        downloadTask = task
        task?.resume()
    }
}

// MARK: - Mod cell

private final class ModrinthModCell: UITableViewCell {
    let modIconView = ModrinthIconView()
    let modTitleLabel = UILabel()
    let modAuthorLabel = UILabel()
    let modDescriptionLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier identifier: String?) {
        super.init(style: .default, reuseIdentifier: identifier)
        accessoryType = .disclosureIndicator
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)

        modIconView.translatesAutoresizingMaskIntoConstraints = false
        modIconView.contentMode = .scaleAspectFit
        modIconView.clipsToBounds = true
        modIconView.layer.cornerRadius = 6
        modIconView.backgroundColor = UIColor.secondarySystemBackground
        modIconView.tintColor = UIColor.secondaryLabel
        contentView.addSubview(modIconView)

        modTitleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        modAuthorLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        modAuthorLabel.textColor = UIColor.secondaryLabel
        modDescriptionLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        modDescriptionLabel.textColor = UIColor.secondaryLabel
        for label in [modTitleLabel, modAuthorLabel, modDescriptionLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        let text = UIStackView(arrangedSubviews: [modTitleLabel, modAuthorLabel, modDescriptionLabel])
        text.axis = .vertical
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(text)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            modIconView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            modIconView.topAnchor.constraint(equalTo: margins.topAnchor),
            modIconView.widthAnchor.constraint(equalToConstant: 44),
            modIconView.heightAnchor.constraint(equalToConstant: 44),
            modIconView.bottomAnchor.constraint(lessThanOrEqualTo: margins.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: modIconView.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            text.topAnchor.constraint(equalTo: margins.topAnchor),
            text.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        ])
        separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        modIconView.cancelImageDownloadTask()
        modIconView.image = nil
    }

    func configure(withProject project: [String: Any]) {
        modTitleLabel.text = mrString(project["title"])
        modAuthorLabel.text = mrString(project["author"])
        modAuthorLabel.isHidden = (modAuthorLabel.text ?? "").isEmpty
        modDescriptionLabel.text = mrString(project["description"])
        modDescriptionLabel.isHidden = (modDescriptionLabel.text ?? "").isEmpty
        accessibilityLabel = [modTitleLabel.text ?? "", modAuthorLabel.text ?? "", modDescriptionLabel.text ?? ""].joined(separator: ". ")

        modIconView.cancelImageDownloadTask()
        let placeholder = UIImage(named: "DefaultProfile") ?? UIImage(systemName: "cube.box")
        modIconView.image = placeholder
        if let iconURL = mrString(project["imageUrl"]), iconURL.count > 0, let url = URL(string: iconURL) {
            modIconView.setImage(with: url, placeholder: placeholder)
        }
    }
}

// MARK: - Categories picker

private final class ModrinthCategoriesViewController: UITableViewController {
    var categories: [String]?
    var records: [[String: Any]]?
    var provider: String?
    var contentType: String?
    var selectedCategories = Set<String>()
    var error: Error?
    var loading = false
    var catalogLoaded: (([[String: Any]]) -> Void)?
    var selectionApplied: (([String]) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = localize("mods.filter.categories")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(apply))
        if categories == nil { loadCategories() }
    }

    @objc func cancel() {
        dismiss(animated: true, completion: nil)
    }

    @objc func apply() {
        selectionApplied?(selectedCategories.sorted { ($0 as NSString).compare($1) == .orderedAscending })
        dismiss(animated: true, completion: nil)
    }

    func loadCategories() {
        if loading { return }
        loading = true
        error = nil
        tableView.reloadData()
        let provider = self.provider
        let contentType = self.contentType ?? "mod"
        DispatchQueue.global(qos: .userInitiated).async {
            let api = mrContentAPI(provider)
            let records = mrCall(api, "categoriesForContentType:", contentType as NSString) as? NSArray
            let categories = records?.value(forKey: "id") as? [String]
            let error = api.lastError
            DispatchQueue.main.async {
                self.loading = false
                self.categories = categories
                let converted = records as? [[String: Any]]
                self.records = converted
                self.error = error
                if let converted = converted { self.catalogLoaded?(converted) }
                self.tableView.reloadData()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? 1 : max(1, categories?.count ?? 0)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 1 ? localize(provider == "curseforge" ? "content.categories.curseforge_help" : "mods.filter.categories_help") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        var selected = false
        if indexPath.section == 0 {
            cell.textLabel?.text = localize("mods.filter.categories_all")
            cell.imageView?.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
            selected = selectedCategories.isEmpty
        } else if let categories = categories, categories.count > 0 {
            let category = categories[indexPath.row]
            let record = (records != nil && indexPath.row < records!.count) ? records![indexPath.row] : [:]
            let name = mrString(record["name"]) ?? ""
            let slug = mrString(record["slug"]) ?? category
            cell.textLabel?.text = name.count > 0 ? name : mrCategoryTitle(slug)
            cell.imageView?.image = UIImage(systemName: mrCategorySymbol(slug)) ?? UIImage(systemName: "tag")
            selected = selectedCategories.contains(category)
        } else {
            cell.textLabel?.text = localize(loading ? "mods.loading" : (error != nil ? "mods.retry" : "mods.filter.categories_empty"))
            cell.detailTextLabel?.text = error?.localizedDescription
            cell.selectionStyle = error != nil ? .default : .none
        }
        cell.imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        cell.imageView?.tintColor = selected ? UIColor.systemBlue : UIColor.secondaryLabel
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            selectedCategories.removeAll()
        } else if let categories = categories, categories.count > 0 {
            let category = categories[indexPath.row]
            if selectedCategories.contains(category) {
                selectedCategories.remove(category)
            } else if provider != "curseforge" || selectedCategories.count < 10 {
                selectedCategories.insert(category)
            }
        } else if error != nil {
            loadCategories()
            return
        }
        tableView.reloadData()
    }
}

// MARK: - Download cell

private final class ModrinthDownloadCell: UITableViewCell {
    let title = UILabel()
    let summary = UILabel()
    let downloadProgress = UIProgressView()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        title.font = UIFont.preferredFont(forTextStyle: .subheadline)
        summary.font = UIFont.preferredFont(forTextStyle: .footnote)
        summary.textColor = UIColor.secondaryLabel
        for label in [title, summary] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let stack = UIStackView(arrangedSubviews: [title, downloadProgress, summary])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        ])
        selectionStyle = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Versions list of one project

private final class ModrinthVersionsViewController: UITableViewController {
    var project: [String: Any] = [:]
    var filters: [String: Any] = [:]
    var versions: [[String: Any]]?
    var error: Error?
    var loading = false
    var loadGeneration = 0
    var contextSignature: NSArray?
    var targetProfileName: String = ""
    var renderSignature: String?
    var installation: ModrinthModInstallation?
    var lastAttempt: [String: Any]?
    var retryAfterChecking = false
    var downloadCell: ModrinthDownloadCell?

    private var projectContentType: String { return mrString(project["contentType"]) ?? "mod" }
    private var projectProvider: String? { return mrString(project["provider"]) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mrString(project["title"])
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        NotificationCenter.default.addObserver(self, selector: #selector(profileChanged(_:)), name: PLProfilesDidChangeNotification, object: nil)
        refreshContext()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshContext()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func profileChanged(_ notification: Notification) {
        DispatchQueue.main.async { self.refreshContext() }
    }

    func refreshContext() {
        let context = MRProfileContext()
        let signature = [context.root ?? "", context.name ?? "", context.gameDir, mrString(context.profile["lastVersionId"]) ?? ""] as NSArray
        if signature.isEqual(contextSignature) { return }
        if contextSignature != nil {
            if installation?.busy == true { installation?.cancel() }
            filters = mrDefaults(profile: context.profile, root: context.root, contentType: projectContentType)
        }
        contextSignature = signature
        targetProfileName = context.name ?? ""
        installation?.stateChanged = nil
        let base = ("\(context.root ?? "")/\(context.gameDir)" as NSString).standardizingPath
        let directory = (base as NSString).appendingPathComponent(mrContentFolder(projectContentType))
        let installationClass: AnyObject = ModrinthModInstallation.self
        installation = mrCall(installationClass, "installationForDirectory:projectID:provider:",
                              directory as NSString,
                              (mrString(project["id"]) ?? "") as NSString,
                              (projectProvider ?? "modrinth") as NSString) as? ModrinthModInstallation
        lastAttempt = nil
        retryAfterChecking = false
        versions = nil
        loading = false
        installation?.stateChanged = { [weak self] in self?.installationChanged() }
        loadVersions()
    }

    func loadVersions() {
        if loading { return }
        loading = true
        error = nil
        loadGeneration += 1
        let generation = loadGeneration
        let projectID = mrString(project["id"]) ?? ""
        let filters = self.filters
        let provider = projectProvider
        let contentType = projectContentType
        tableView.reloadData()
        DispatchQueue.global(qos: .userInitiated).async {
            let api = mrContentAPI(provider)
            // All CurseForge file identities allow recognition of older versions outside the filters.
            let requestFilters: [String: Any] = provider == "curseforge" ? ["contentType": contentType] : filters
            let knownVersions = mrCall(api, "versionsForProject:filters:", projectID as NSString, requestFilters as NSDictionary) as? NSArray
            var matching: [[String: Any]]? = nil
            if let knownVersions = knownVersions {
                let filtersClass: AnyObject = ModrinthSearchFilters.self
                matching = mrCall(filtersClass, "versions:matchingFilters:", knownVersions, filters as NSDictionary) as? [[String: Any]]
            }
            let error = api.lastError
            DispatchQueue.main.async {
                if generation != self.loadGeneration { return }
                self.loading = false
                self.versions = matching
                self.error = error
                if let installation = self.installation {
                    mrCallVoid(installation, "inspectWithVersions:", knownVersions ?? NSArray())
                }
                self.tableView.reloadData()
            }
        }
    }

    func installationChanged() {
        guard let installation = installation else { return }
        if retryAfterChecking && !installation.checking && !installation.busy {
            retryAfterChecking = false
            if installation.error == nil {
                mrCallVoid(installation, "installVersion:resolvingDependenciesWithFilters:", lastAttempt.map { $0 as NSDictionary }, filters as NSDictionary)
                return
            }
        }
        let signature = "\(installation.checking ? 1 : 0)/\(installation.busy ? 1 : 0)/\(installation.verifying ? 1 : 0)/\(mrDescribe(installation.error))/\(mrDescribe(installation.installedVersions))"
        if signature != renderSignature {
            renderSignature = signature
            downloadCell = nil
            tableView.reloadData()
        } else if installation.busy {
            updateDownloadCell()
        }
    }

    private var installedVersionEntries: [[String: Any]] {
        return (installation?.installedVersions as? [[String: Any]]) ?? []
    }

    func updateDownloadCell() {
        guard let installation = installation else { return }
        let installing = installation.installingVersion as? [String: Any]
        let version = mrString(installing?["version_number"]) ?? mrString(installing?["name"]) ?? ""
        downloadCell?.title.text = String(format: localize(installation.verifying ? "mods.install.verifying" : "mods.install.downloading"), version)
        let progress = installation.progress
        let fraction = progress?.fractionCompleted ?? 0
        downloadCell?.downloadProgress.progress = Float(fraction)
        let received = ByteCountFormatter.string(fromByteCount: progress?.completedUnitCount ?? 0, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress?.totalUnitCount ?? 0, countStyle: .file)
        downloadCell?.summary.text = String(format: localize("mods.install.progress"), Int32(fraction * 100), received, total)
        downloadCell?.downloadProgress.accessibilityLabel = downloadCell?.title.text
        downloadCell?.downloadProgress.accessibilityValue = downloadCell?.summary.text
    }

    func isCurrentVersion(_ version: [String: Any]) -> Bool {
        let installed = installedVersionEntries
        return installed.count == 1 && mrEqual(mrDict(installed[0]["version"])?["id"], version["id"])
    }

    func action(forVersion version: [String: Any]) -> String {
        if isCurrentVersion(version) { return "mods.install.installed" }
        let installed = installedVersionEntries
        if installed.isEmpty { return "mods.install.install" }
        let present = mrDict(installed[0]["version"])?["date_published"]
        let candidate = version["date_published"]
        if let present = present as? String, let candidate = candidate as? String {
            return (candidate as NSString).compare(present) == .orderedAscending ? "mods.install.downgrade" : "mods.install.update"
        }
        return "mods.install.change"
    }

    func installVersion(_ version: [String: Any]) {
        guard let installation = installation else { return }
        if mrBool(version["downloadUnavailable"]) || installation.busy || installation.checking || isCurrentVersion(version) { return }
        lastAttempt = version
        mrCallVoid(installation, "installVersion:resolvingDependenciesWithFilters:", version as NSDictionary, filters as NSDictionary)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return (installation?.busy == true || installation?.error != nil) ? 4 : 3
        }
        return max(1, versions?.count ?? 0)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? mrFilterSummary(filters) : localize("mods.versions.title")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return section == 0 ? String(format: localize("content.install.profile"), mrContentFolder(projectContentType), targetProfileName) : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 && indexPath.row == 3 && installation?.busy == true {
            let busyCell = ModrinthDownloadCell()
            downloadCell = busyCell
            let cancel = UIButton(type: .system)
            cancel.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            cancel.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
            cancel.accessibilityLabel = localize("mods.install.cancel")
            cancel.isEnabled = !(installation?.verifying ?? false)
            cancel.addAction(UIAction { [weak self] _ in self?.installation?.cancel() }, for: .touchUpInside)
            busyCell.accessoryView = cancel
            updateDownloadCell()
            return busyCell
        }
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        let installed = installedVersionEntries
        if indexPath.section == 0 {
            cell.selectionStyle = .none
            if indexPath.row == 0 {
                var names: [String] = []
                for entry in installed {
                    let version = mrDict(entry["version"])
                    if let name = mrString(version?["version_number"]) ?? mrString(version?["name"]) ?? mrString(version?["id"]), !names.contains(name) {
                        names.append(name)
                    }
                }
                if installation?.checking == true || (loading && names.isEmpty) {
                    cell.textLabel?.text = localize("mods.install.checking")
                } else if names.count > 0 {
                    cell.textLabel?.text = String(format: localize("mods.install.present"), names.joined(separator: ", "))
                } else {
                    cell.textLabel?.text = localize(installation?.error != nil ? "mods.install.unknown" : "mods.install.absent")
                }
                cell.detailTextLabel?.text = installed.count > 1 ? localize("mods.install.duplicates") : mrString(installed.first?["filename"])
            } else if indexPath.row == 1 {
                cell.textLabel?.text = mrString(project["description"])
            } else if indexPath.row == 2 {
                cell.textLabel?.text = String(format: localize("content.open_project"), mrProviderTitle(projectProvider))
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            } else {
                cell.textLabel?.text = localize("mods.install.retry")
                cell.detailTextLabel?.text = installation?.error?.localizedDescription
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }
        } else if let versions = versions, versions.count > 0 {
            let version = versions[indexPath.row]
            cell.textLabel?.text = mrString(version["name"]) ?? mrString(version["version_number"])
            var versionType = mrString(version["version_type"]) ?? ""
            if ["release", "beta", "alpha"].contains(versionType) {
                versionType = localize("content.version." + versionType)
            }
            var tags: [String] = []
            let gameVersions = (version["game_versions"] as? [String])?.joined(separator: ", ") ?? ""
            let loaders = (version["loaders"] as? [String])?.joined(separator: ", ") ?? ""
            for tag in [gameVersions, loaders, versionType] where tag.count > 0 {
                tags.append(tag)
            }
            let unavailable = mrBool(version["downloadUnavailable"])
            cell.detailTextLabel?.text = unavailable ? localize("content.download.restricted") : tags.joined(separator: " · ")
            let button = UIButton(type: .system)
            let operation = localize(unavailable ? "content.download.unavailable_title" : action(forVersion: version))
            button.setTitle(operation, for: .normal)
            button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.sizeToFit()
            button.frame = CGRect(x: 0, y: 0, width: max(44, button.frame.size.width), height: max(44, button.frame.size.height))
            let current = isCurrentVersion(version)
            button.isEnabled = !unavailable && !loading && installation?.busy != true && installation?.checking != true
                && installation?.error == nil && !ModrinthModInstallation.isInstalling() && !current
            if current { button.setTitleColor(UIColor.systemGreen, for: .disabled) }
            button.accessibilityLabel = "\(operation) \(cell.textLabel?.text ?? "(null)")"
            button.accessibilityHint = String(format: localize("content.download.hint"), mrContentFolder(projectContentType))
            button.addAction(UIAction { [weak self] _ in self?.installVersion(version) }, for: .touchUpInside)
            cell.accessoryView = button
        } else {
            cell.textLabel?.text = localize(loading ? "mods.loading" : (error != nil ? "mods.retry" : "mods.versions.empty"))
            cell.detailTextLabel?.text = error?.localizedDescription
            cell.selectionStyle = error != nil ? .default : .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            if let versions = versions, versions.count > 0, installation?.error == nil {
                installVersion(versions[indexPath.row])
            } else if error != nil {
                loadVersions()
            }
        } else if indexPath.row == 2 {
            var url = mrString(project["websiteUrl"]) ?? ""
            if url.isEmpty {
                url = "https://modrinth.com/\(mrString(project["contentType"]) ?? "mod")/\(mrString(project["id"]) ?? "(null)")"
            }
            if let link = URL(string: url), link.scheme?.lowercased() == "https" {
                openLink(self, link)
            }
        } else if indexPath.row == 3 && installation?.busy != true {
            retryAfterChecking = lastAttempt != nil
            if let installation = installation {
                mrCallVoid(installation, "inspectWithVersions:", (versions ?? []).map { $0 as NSDictionary } as NSArray)
            }
        }
    }
}

// MARK: - Browser

@objc(ModrinthModsViewController)
@objcMembers
class ModrinthModsViewController: UITableViewController, UISearchBarDelegate {
    private var searchBar = UISearchBar()
    private var providerToggle = UISegmentedControl()
    private var provider = "modrinth"
    private var filters: [String: Any] = [:]
    private var profileDefaults: [String: Any] = [:]
    private var profileSignature: NSArray?
    private var profileName = ""
    private var results = NSArray()
    private var searchError: Error?
    private var loading = false
    private var reachedLastPage = false
    private var requestGeneration = 0
    private var categoryCatalog: [[String: Any]]?
    private var installedEntries: NSArray?
    private var installedLoading = false
    private var installedError: Error?
    private var installedGeneration = 0
    private var installedOperation: ModrinthModInstallation?

    init() {
        super.init(style: .insetGrouped)
        title = localize("content.title." + contentType())
        provider = "modrinth"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func imageName() -> String { return "magnifyingglass" }
    func contentType() -> String { return "mod" }

    override func viewDidLoad() {
        super.viewDidLoad()
        let isMod = contentType() == "mod"
        providerToggle = UISegmentedControl(items: isMod ? ["Modrinth", "CurseForge", localize("mods.installed.tab")] : ["Modrinth", "CurseForge"])
        providerToggle.setEnabled(CurseForgeAPI.isConfigured(), forSegmentAt: 1)
        providerToggle.selectedSegmentIndex = 0
        providerToggle.accessibilityLabel = localize("content.provider")
        providerToggle.accessibilityIdentifier = "content-provider"
        providerToggle.addTarget(self, action: #selector(providerChanged(_:)), for: .valueChanged)
        searchBar = UISearchBar()
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.accessibilityIdentifier = "content-search"
        updateSearchPlaceholder()
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.size.width, height: 110))
        for view in [providerToggle, searchBar] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            providerToggle.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            providerToggle.leadingAnchor.constraint(equalTo: header.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            providerToggle.trailingAnchor.constraint(equalTo: header.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            providerToggle.heightAnchor.constraint(equalToConstant: 32),
            searchBar.topAnchor.constraint(equalTo: providerToggle.bottomAnchor, constant: 6),
            searchBar.leadingAnchor.constraint(equalTo: header.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            searchBar.trailingAnchor.constraint(equalTo: header.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            searchBar.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4)
        ])
        tableView.tableHeaderView = header
        tableView.keyboardDismissMode = .onDrag
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        NotificationCenter.default.addObserver(self, selector: #selector(providerConfigurationChanged(_:)), name: NSNotification.Name("CurseForgeConfigurationDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(profileChanged(_:)), name: PLProfilesDidChangeNotification, object: nil)
        refreshProfile()
        refreshProviderAvailability()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshProfile()
        refreshProviderAvailability()
        if isInstalledMode && installedOperation?.busy != true {
            refreshInstalled(true)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    func profileChanged(_ notification: Notification) {
        DispatchQueue.main.async { self.refreshProfile() }
    }

    func refreshProfile() {
        let context = MRProfileContext()
        let root = context.root ?? ""
        let defaults = mrDefaults(profile: context.profile, root: root, contentType: contentType())
        let signature = [root, context.name ?? "", mrString(context.profile["lastVersionId"]) ?? "", mrString(context.profile["gameDir"]) ?? "", defaults as NSDictionary] as NSArray
        if signature.isEqual(profileSignature) { return }
        if installedOperation?.busy == true { installedOperation?.cancel() }
        installedGeneration += 1
        installedEntries = nil
        profileSignature = signature
        profileName = context.name ?? ""
        profileDefaults = defaults
        filters = defaults
        reloadSearch()
    }

    var isInstalledMode: Bool { return providerToggle.selectedSegmentIndex == 2 }

    func providerConfigurationChanged(_ notification: Notification) {
        DispatchQueue.main.async { self.refreshProviderAvailability() }
    }

    func refreshProviderAvailability() {
        let enabled = CurseForgeAPI.isConfigured()
        providerToggle.setEnabled(enabled, forSegmentAt: 1)
        if !enabled && providerToggle.selectedSegmentIndex == 1 {
            providerToggle.selectedSegmentIndex = 0
            providerChanged(providerToggle)
        }
    }

    private func filterRow(_ row: Int) -> Int {
        return (contentType() == "mod" || row == 0) ? row : row + 1
    }

    private func categoryTitle(_ identifier: String) -> String {
        for record in categoryCatalog ?? [] where mrEqual(record["id"], identifier) {
            let name = mrString(record["name"]) ?? ""
            return name.count > 0 ? name : mrCategoryTitle(mrString(record["slug"]) ?? identifier)
        }
        return mrCategoryTitle(identifier)
    }

    private func sortTitle(_ value: String) -> String {
        return provider == "curseforge" && value == "relevance" ? localize("content.sort.popularity") : localize("mods.sort." + value)
    }

    private func updateSearchPlaceholder() {
        if isInstalledMode {
            searchBar.placeholder = localize("mods.installed.search")
            return
        }
        searchBar.placeholder = String(format: localize("content.search_placeholder"), mrProviderTitle(provider))
    }

    func providerChanged(_ sender: UISegmentedControl) {
        searchBar.resignFirstResponder()
        if sender.selectedSegmentIndex == 1 && !CurseForgeAPI.isConfigured() { sender.selectedSegmentIndex = 0 }
        if isInstalledMode {
            requestGeneration += 1
            updateSearchPlaceholder()
            refreshInstalled(true)
            return
        }
        provider = sender.selectedSegmentIndex == 1 ? "curseforge" : "modrinth"
        categoryCatalog = nil
        filters["categories"] = [String]()
        if provider == "curseforge" && mrString(filters["index"]) == "follows" { filters["index"] = "relevance" }
        if provider == "curseforge" && mrString(filters["loader"]) == "rift" { filters["loader"] = "" }
        updateSearchPlaceholder()
        reloadSearch()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        reloadSearch()
    }

    private func clearResults() {
        requestGeneration += 1
        results = NSArray()
        searchError = nil
        reachedLastPage = false
        loading = true
        tableView.reloadData()
    }

    func reloadSearch() {
        if isInstalledMode {
            refreshInstalled(false)
            return
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reloadSearch), object: nil)
        clearResults()
        loadPage(false)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if isInstalledMode {
            tableView.reloadData()
            return
        }
        if profileSignature == nil || mrString(filters["name"]) == searchText { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reloadSearch), object: nil)
        // Invalidate in-flight responses immediately, before the debounce fires.
        clearResults()
        perform(#selector(reloadSearch), with: nil, afterDelay: 0.35)
    }

    func loadPage(_ append: Bool) {
        if append && (loading || reachedLastPage) { return }
        loading = true
        searchError = nil
        filters["name"] = searchBar.text ?? ""
        filters["provider"] = provider
        let filtersCopy = filters as NSDictionary
        let previous: NSMutableArray? = append ? NSMutableArray(array: results) : nil
        requestGeneration += 1
        let generation = requestGeneration
        tableView.reloadData()
        DispatchQueue.global(qos: .userInitiated).async {
            // Separate API objects keep overlapping requests from sharing pagination/error state.
            let api = mrContentAPI(filtersCopy["provider"] as? String)
            let found = mrCall(api, "searchModWithFilters:previousPageResult:", filtersCopy, previous) as? NSArray
            let error = api.lastError
            let lastPage = api.reachedLastPage
            DispatchQueue.main.async {
                if generation != self.requestGeneration { return }
                self.loading = false
                self.searchError = error
                if let found = found {
                    self.results = found
                    self.reachedLastPage = lastPage
                }
                self.tableView.reloadData()
            }
        }
    }

    // MARK: Table data

    override func numberOfSections(in tableView: UITableView) -> Int { return 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isInstalledMode {
            return section == 0 ? (installedOperation?.busy == true ? 1 : 2) : max(1, visibleInstalledEntries.count)
        }
        if section == 0 { return contentType() == "mod" ? 5 : 4 }
        return results.count + ((loading || searchError != nil || results.count == 0 || !reachedLastPage) ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if isInstalledMode { return localize(section == 0 ? "mods.installed.actions" : "mods.installed.tab") }
        return localize(section == 0 ? "mods.filters" : "content.title." + contentType())
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if isInstalledMode { return section == 0 ? profileName : nil }
        if section != 0 { return nil }
        return String(format: localize("mods.profile_footer"), profileName)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if isInstalledMode { return installedCell(tableView, indexPath: indexPath) }
        if indexPath.section == 0 {
            let row = filterRow(indexPath.row)
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = localize(["mods.filter.minecraft", "mods.filter.loader", "mods.filter.categories", "mods.filter.sort", "mods.filter.reset"][row])
            cell.accessoryType = .disclosureIndicator
            if row == 0 {
                let version = mrString(filters["mcVersion"]) ?? ""
                cell.detailTextLabel?.text = version.count > 0 ? version : localize("mods.filter.any")
            }
            if row == 1 { cell.detailTextLabel?.text = mrLoaderTitle(mrString(filters["loader"])) }
            if row == 2 {
                let categories = (filters["categories"] as? [String]) ?? []
                if categories.isEmpty {
                    cell.detailTextLabel?.text = localize("mods.filter.categories_all")
                } else if categories.count == 1 {
                    cell.detailTextLabel?.text = categoryTitle(categories[0])
                } else {
                    cell.detailTextLabel?.text = String(format: localize("mods.filter.categories_count"), categories.count)
                }
                cell.accessibilityValue = categories.map { categoryTitle($0) }.joined(separator: ", ")
            }
            if row == 3 { cell.detailTextLabel?.text = sortTitle(mrString(filters["index"]) ?? "") }
            return cell
        }
        if indexPath.row == results.count {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.numberOfLines = 0
            cell.detailTextLabel?.numberOfLines = 0
            let key = loading ? "mods.loading" : (searchError != nil ? "mods.retry" : (results.count == 0 ? "mods.empty" : "mods.load_more"))
            let unconfigured = provider == "curseforge" && !CurseForgeAPI.isConfigured()
            cell.textLabel?.text = unconfigured ? localize("content.curseforge.pending") : localize(key)
            cell.detailTextLabel?.text = searchError?.localizedDescription
            if unconfigured {
                cell.selectionStyle = .none
                return cell
            }
            cell.selectionStyle = (loading || (searchError == nil && results.count == 0)) ? .none : .default
            return cell
        }
        let cell = (tableView.dequeueReusableCell(withIdentifier: "mod") as? ModrinthModCell)
            ?? ModrinthModCell(style: .default, reuseIdentifier: "mod")
        cell.configure(withProject: (results[indexPath.row] as? [String: Any]) ?? [:])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isInstalledMode {
            selectInstalled(indexPath)
            return
        }
        if indexPath.section == 0 {
            searchBar.resignFirstResponder()
            let row = filterRow(indexPath.row)
            if row == 0 {
                editMinecraftVersion()
            } else if row == 1 {
                pickValues(provider == "curseforge" ? ["", "fabric", "quilt", "forge", "neoforge", "liteloader"] : ["", "fabric", "quilt", "forge", "neoforge", "liteloader", "rift"], key: "loader", indexPath: indexPath)
            } else if row == 2 {
                pickCategories()
            } else if row == 3 {
                pickValues(provider == "curseforge" ? ["relevance", "downloads", "newest", "updated"] : ["relevance", "downloads", "follows", "newest", "updated"], key: "index", indexPath: indexPath)
            } else {
                filters = profileDefaults
                reloadSearch()
            }
        } else if indexPath.row < results.count {
            let vc = ModrinthVersionsViewController(style: .insetGrouped)
            vc.project = (results[indexPath.row] as? [String: Any]) ?? [:]
            vc.filters = filters
            searchBar.resignFirstResponder()
            navigationController?.pushViewController(vc, animated: true)
        } else if !loading {
            loadPage(results.count > 0)
        }
    }

    // MARK: Installed content

    private var installedDirectory: String {
        let context = MRProfileContext()
        let root = context.root ?? ""
        let base = ("\(root)/\(context.gameDir)" as NSString).standardizingPath
        return (base as NSString).appendingPathComponent("mods")
    }

    private var visibleInstalledEntries: [[String: Any]] {
        let all = (installedEntries as? [[String: Any]]) ?? []
        let query = searchBar.text ?? ""
        if query.isEmpty { return all }
        return all.filter { entry in
            let filename = mrString(entry["filename"])
            let title = mrString(mrDict(entry["project"])?["title"])
            return filename?.localizedCaseInsensitiveContains(query) == true || title?.localizedCaseInsensitiveContains(query) == true
        }
    }

    func refreshInstalled(_ updates: Bool) {
        installedGeneration += 1
        let generation = installedGeneration
        let directory = installedDirectory
        let context = profileSignature
        let filters = profileDefaults as NSDictionary
        installedLoading = true
        installedError = nil
        tableView.reloadData()
        DispatchQueue.global(qos: .userInitiated).async {
            var error: Error?
            var entries = mrInstalledEntries(directory: directory, identify: updates, error: &error)
            let firstEntries = entries
            let firstError = error
            DispatchQueue.main.async {
                if generation != self.installedGeneration || !(context?.isEqual(self.profileSignature) ?? (self.profileSignature == nil)) { return }
                self.installedEntries = firstEntries
                self.installedError = firstError
                self.installedLoading = updates && firstError == nil
                self.tableView.reloadData()
            }
            if updates, let current = entries {
                let managerClass: AnyObject = InstalledModsManager.self
                entries = mrCall(managerClass, "checkUpdates:filters:", current, filters) as? NSArray
            }
            let finalEntries = entries
            let finalError = error
            DispatchQueue.main.async {
                if generation != self.installedGeneration || !(context?.isEqual(self.profileSignature) ?? (self.profileSignature == nil)) { return }
                self.installedEntries = finalEntries
                self.installedError = finalError
                self.installedLoading = false
                self.tableView.reloadData()
            }
        }
    }

    private func installedCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            if let operation = installedOperation, operation.busy {
                cell.textLabel?.text = localize(operation.checking ? "mods.installed.resolving" : "mods.installed.downloading")
                cell.detailTextLabel?.text = mrString((operation.installingVersion as? [String: Any])?["version_number"])
                if let progress = operation.progress, progress.totalUnitCount > 0 {
                    cell.detailTextLabel?.text = String(format: "%@ · %d%%", cell.detailTextLabel?.text ?? "", Int32(100 * progress.fractionCompleted))
                }
                let cancel = UIButton(type: .system)
                cancel.setTitle(localize("mods.install.cancel"), for: .normal)
                cancel.sizeToFit()
                cancel.isEnabled = !operation.verifying
                cancel.addAction(UIAction { [weak self] _ in self?.installedOperation?.cancel() }, for: .touchUpInside)
                cell.accessoryView = cancel
            } else {
                cell.textLabel?.text = localize(indexPath.row == 0 ? "mods.installed.check_updates" : "mods.installed.dependencies")
                cell.detailTextLabel?.text = (indexPath.row == 0 && installedLoading) ? localize("mods.loading") : nil
                cell.textLabel?.textColor = (ModrinthModInstallation.isInstalling() || installedLoading) ? UIColor.secondaryLabel : view.tintColor
            }
            return cell
        }
        let entries = visibleInstalledEntries
        if entries.isEmpty {
            cell.textLabel?.text = localize(installedLoading ? "mods.loading" : (installedError != nil ? "mods.retry" : "mods.installed.empty"))
            cell.detailTextLabel?.text = installedError?.localizedDescription
            return cell
        }
        let entry = entries[indexPath.row]
        let project = mrDict(entry["project"])
        let filename = mrString(entry["filename"])
        let title = mrString(project?["title"]) ?? filename ?? ""
        let status = localize(mrBool(entry["enabled"]) ? "mods.installed.enabled" : "mods.installed.disabled")
        let versionDict = mrDict(entry["version"])
        let version = mrString(versionDict?["version_number"]) ?? mrString(versionDict?["name"]) ?? ""
        let update: String
        if let updateDict = mrDict(entry["update"]) {
            update = String(format: localize("mods.installed.update_available"), mrString(updateDict["version_number"]) ?? mrString(updateDict["name"]) ?? "(null)")
        } else if let message = mrString(entry["updateError"]) ?? mrString(entry["lookupError"]) {
            update = message
        } else {
            let key: String
            if entry["version"] == nil {
                key = "mods.installed.unidentified"
            } else if mrBool(entry["noCompatibleVersion"]) {
                key = "mods.installed.no_compatible"
            } else if mrBool(entry["updatesChecked"]) {
                key = "mods.installed.up_to_date"
            } else {
                key = "mods.installed.not_checked"
            }
            update = localize(key)
        }
        let summary = "\(version)\(version.count > 0 ? " · " : "")\(status)"
        let mod = (tableView.dequeueReusableCell(withIdentifier: "installed-mod") as? ModrinthModCell)
            ?? ModrinthModCell(style: .default, reuseIdentifier: "installed-mod")
        mod.configure(withProject: [
            "title": title,
            "author": summary,
            "description": "\(update)\n\(filename ?? "(null)")",
            "imageUrl": mrString(project?["imageUrl"]) ?? ""
        ])
        mod.accessibilityIdentifier = "installed-" + (filename ?? "")
        return mod
    }

    private func runInstalledVersion(_ version: [String: Any]?, entry: [String: Any]?, enable: Bool) {
        if ModrinthModInstallation.isInstalling() || installedLoading { return }
        let directory = installedDirectory
        let context = profileSignature
        let installationClass: AnyObject = ModrinthModInstallation.self
        let versionInfo = mrDict(entry?["version"])
        let operation = mrCall(installationClass, "installationForDirectory:projectID:provider:",
                               directory as NSString,
                               (mrString(versionInfo?["project_id"]) ?? "") as NSString,
                               (mrString(entry?["provider"]) ?? "modrinth") as NSString) as? ModrinthModInstallation
        installedOperation = operation
        var wasBusy = false
        operation?.stateChanged = { [weak self] in
            guard let self = self, context?.isEqual(self.profileSignature) ?? (self.profileSignature == nil) else { return }
            guard let operation = self.installedOperation else { return }
            if operation.busy { wasBusy = true }
            if wasBusy && !operation.busy && !operation.checking {
                wasBusy = false
                if let error = operation.error { self.showInstalledError(error) }
                self.refreshInstalled(true)
            } else if self.isInstalledMode {
                self.tableView.reloadData()
            }
        }
        guard let operation = operation else { return }
        let defaults = profileDefaults as NSDictionary
        if let version = version {
            if enable {
                mrCallVoid(operation, "enableVersion:resolvingDependenciesWithFilters:", version as NSDictionary, defaults)
            } else {
                mrCallVoid(operation, "installVersion:resolvingDependenciesWithFilters:", version as NSDictionary, defaults)
            }
        } else {
            mrCallVoid(operation, "resolveDependenciesWithFilters:", defaults)
        }
    }

    private func showInstalledError(_ error: Error) {
        let alert = UIAlertController(title: localize("Error"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: localize("OK"), style: .default, handler: nil))
        if presentedViewController == nil {
            present(alert, animated: true, completion: nil)
        }
    }

    private func changeInstalledEntry(_ entry: [String: Any], remove: Bool) {
        let directory = installedDirectory
        let context = profileSignature
        installedLoading = true
        tableView.reloadData()
        DispatchQueue.global(qos: .userInitiated).async {
            var error: Error?
            if remove {
                mrRemoveEntry(entry as NSDictionary, directory: directory, error: &error)
            } else {
                mrSetEntry(entry as NSDictionary, enabled: !mrBool(entry["enabled"]), directory: directory, error: &error)
            }
            let finalError = error
            DispatchQueue.main.async {
                if !(context?.isEqual(self.profileSignature) ?? (self.profileSignature == nil)) { return }
                self.installedLoading = false
                if let finalError = finalError { self.showInstalledError(finalError) }
                self.refreshInstalled(true)
            }
        }
    }

    private func selectInstalled(_ indexPath: IndexPath) {
        if ModrinthModInstallation.isInstalling() || installedLoading { return }
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                refreshInstalled(true)
            } else {
                runInstalledVersion(nil, entry: nil, enable: false)
            }
            return
        }
        let entries = visibleInstalledEntries
        if entries.isEmpty {
            if installedError != nil { refreshInstalled(true) }
            return
        }
        let entry = entries[indexPath.row]
        let project = mrDict(entry["project"])
        let filename = mrString(entry["filename"])
        let menu = UIAlertController(title: mrString(project?["title"]) ?? filename, message: filename, preferredStyle: .actionSheet)
        let enabled = mrBool(entry["enabled"])
        let toggleKey = enabled ? "mods.installed.disable" : (entry["version"] != nil ? "mods.installed.enable" : "mods.installed.enable_file")
        menu.addAction(UIAlertAction(title: localize(toggleKey), style: .default) { [weak self] _ in
            if !enabled, let version = mrDict(entry["version"]) {
                self?.runInstalledVersion(version, entry: entry, enable: true)
            } else {
                self?.changeInstalledEntry(entry, remove: false)
            }
        })
        if let update = mrDict(entry["update"]) {
            menu.addAction(UIAlertAction(title: localize("mods.install.update"), style: .default) { [weak self] _ in
                self?.runInstalledVersion(update, entry: entry, enable: false)
            })
        }
        if let project = project {
            menu.addAction(UIAlertAction(title: localize("mods.installed.versions"), style: .default) { [weak self] _ in
                guard let self = self else { return }
                let vc = ModrinthVersionsViewController(style: .insetGrouped)
                vc.project = project
                vc.filters = self.profileDefaults
                self.navigationController?.pushViewController(vc, animated: true)
            })
        }
        menu.addAction(UIAlertAction(title: localize("mods.installed.remove"), style: .destructive) { [weak self] _ in
            let confirm = UIAlertController(title: localize("mods.installed.remove"),
                                            message: String(format: localize("mods.installed.remove_confirm"), filename ?? "(null)"),
                                            preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
            confirm.addAction(UIAlertAction(title: localize("mods.installed.remove"), style: .destructive) { _ in
                self?.changeInstalledEntry(entry, remove: true)
            })
            self?.present(confirm, animated: true, completion: nil)
        })
        menu.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
        let cell = tableView.cellForRow(at: indexPath)
        menu.popoverPresentationController?.sourceView = cell ?? view
        menu.popoverPresentationController?.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.size.width / 2, y: view.bounds.size.height / 2, width: 1, height: 1)
        searchBar.resignFirstResponder()
        present(menu, animated: true, completion: nil)
    }

    // MARK: Filters

    private func pickCategories() {
        let picker = ModrinthCategoriesViewController(style: .insetGrouped)
        picker.records = categoryCatalog
        picker.categories = categoryCatalog?.compactMap { mrString($0["id"]) }
        picker.provider = provider
        picker.contentType = contentType()
        picker.selectedCategories = Set((filters["categories"] as? [String]) ?? [])
        let context = profileSignature
        let provider = self.provider
        picker.catalogLoaded = { [weak self] categories in
            if self?.provider == provider { self?.categoryCatalog = categories }
        }
        picker.selectionApplied = { [weak self] categories in
            guard let self = self, context?.isEqual(self.profileSignature) ?? (self.profileSignature == nil), self.provider == provider else { return }
            if (self.filters["categories"] as? [String]) == categories { return }
            self.filters["categories"] = categories
            self.reloadSearch()
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 420, height: 720)
        searchBar.resignFirstResponder()
        present(navigation, animated: true, completion: nil)
    }

    private func editMinecraftVersion() {
        let alert = UIAlertController(title: localize("mods.filter.minecraft"), message: localize("mods.filter.minecraft_help"), preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.filters["mcVersion"] as? String
            field.placeholder = self?.profileDefaults["mcVersion"] as? String
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: localize("Done"), style: .default) { [weak self, weak alert] _ in
            self?.filters["mcVersion"] = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self?.reloadSearch()
        })
        present(alert, animated: true, completion: nil)
    }

    private func pickValues(_ values: [String], key: String, indexPath: IndexPath) {
        let cell = tableView.cellForRow(at: indexPath)
        let alert = UIAlertController(title: cell?.textLabel?.text, message: nil, preferredStyle: .actionSheet)
        for value in values {
            var title = key == "loader" ? mrLoaderTitle(value) : sortTitle(value)
            if mrString(filters[key]) == value { title = "✓ " + title }
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.filters[key] = value
                self?.reloadSearch()
            })
        }
        alert.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
        alert.popoverPresentationController?.sourceView = cell
        alert.popoverPresentationController?.sourceRect = cell?.bounds ?? .zero
        present(alert, animated: true, completion: nil)
    }
}

@objc(LauncherResourcePacksViewController)
@objcMembers
class LauncherResourcePacksViewController: ModrinthModsViewController {
    override func contentType() -> String { return "resourcepack" }
    override func imageName() -> String { return "photo.on.rectangle.angled" }
}

@objc(LauncherShaderPacksViewController)
@objcMembers
class LauncherShaderPacksViewController: ModrinthModsViewController {
    override func contentType() -> String { return "shader" }
    override func imageName() -> String { return "sun.max" }
}
