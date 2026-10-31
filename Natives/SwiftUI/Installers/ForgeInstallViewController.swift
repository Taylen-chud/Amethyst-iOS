import UIKit
import Darwin

// WFWorkflowProgressView is a private class of WorkflowUIServices that is loaded with dlopen at runtime.
// It is never linked, so it is created with NSClassFromString and driven through KVC and selectors.

// MARK: - Cells

@objc(ForgeVersionCell)
@objcMembers
class ForgeVersionCell: UITableViewCell {
    var versionLabel: UILabel
    var subtitleLabel: UILabel

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        versionLabel = UILabel()
        subtitleLabel = UILabel()
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        versionLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(versionLabel)

        subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = UIColor.secondaryLabel
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(subtitleLabel)

        accessoryType = .disclosureIndicator

        NSLayoutConstraint.activate([
            versionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            versionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
        ])

        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            subtitleLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@objc(MinecraftVersionHeaderView)
@objcMembers
class MinecraftVersionHeaderView: UITableViewHeaderFooterView {
    var titleLabel: UILabel
    var chevronImageView: UIImageView
    var expandCollapseButton: UIButton

    var isExpanded: Bool = false {
        didSet {
            // Animate chevron rotation
            let expanded = isExpanded
            UIView.animate(withDuration: 0.3) {
                self.chevronImageView.transform = expanded
                    ? CGAffineTransform(rotationAngle: CGFloat.pi / 2)
                    : CGAffineTransform.identity
            }
        }
    }

    override init(reuseIdentifier: String?) {
        titleLabel = UILabel()
        chevronImageView = UIImageView(image: UIImage(systemName: "chevron.right"))
        expandCollapseButton = UIButton(type: .system)
        super.init(reuseIdentifier: reuseIdentifier)

        let containerView = UIView()
        containerView.backgroundColor = UIColor.systemGroupedBackground
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)

        titleLabel.font = UIFont.boldSystemFont(ofSize: 18)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        chevronImageView.tintColor = UIColor.systemGray
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        chevronImageView.contentMode = .scaleAspectFit
        containerView.addSubview(chevronImageView)

        expandCollapseButton.translatesAutoresizingMaskIntoConstraints = false
        expandCollapseButton.backgroundColor = UIColor.clear
        containerView.addSubview(expandCollapseButton)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronImageView.leadingAnchor, constant: -16)
        ])

        NSLayoutConstraint.activate([
            chevronImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            chevronImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 20),
            chevronImageView.heightAnchor.constraint(equalToConstant: 20)
        ])

        NSLayoutConstraint.activate([
            expandCollapseButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            expandCollapseButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            expandCollapseButton.topAnchor.constraint(equalTo: containerView.topAnchor),
            expandCollapseButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - NSString-style helpers (the original leaned on NSString semantics)

/// -[NSString integerValue]: leading whitespace, optional sign, digits; anything else gives 0
private func forgeIntegerValue(_ string: String) -> Int {
    var result = 0
    var negative = false
    var started = false
    var sawDigit = false
    for scalar in string.unicodeScalars {
        if !started {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { continue }
            started = true
            if scalar == "-" { negative = true; continue }
            if scalar == "+" { continue }
        }
        guard scalar.value >= 48 && scalar.value <= 57 else { break }
        sawDigit = true
        let digit = Int(scalar.value - 48)
        let (multiplied, overflow1) = result.multipliedReportingOverflow(by: 10)
        let (added, overflow2) = multiplied.addingReportingOverflow(digit)
        if overflow1 || overflow2 {
            return negative ? Int.min : Int.max
        }
        result = added
    }
    if !sawDigit { return 0 }
    return negative ? -result : result
}

private func forgeHyphenRange(_ string: String) -> NSRange {
    return (string as NSString).range(of: "-")
}

/// Run `body` with the lock held
private func forgeLocked<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

// MARK: - XML metadata parsing

/// Per-load parser state, so a parse that is still running when the vendor changes does not share
/// the version string buffer with the next one. Feeds versions back to the controller.
private final class ForgeMetadataParserDelegate: NSObject, XMLParserDelegate {
    weak var owner: ForgeInstallViewController?
    var isVersionElement = false
    var currentVersionValue = ""

    init(owner: ForgeInstallViewController) {
        self.owner = owner
        super.init()
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        owner?.parserDidEndDocument()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        isVersionElement = (elementName == "version")
        if isVersionElement {
            currentVersionValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isVersionElement {
            currentVersionValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "version" {
            let versionString = currentVersionValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if versionString.count > 0 {
                owner?.addVersionToList(versionString)
            }
            isVersionElement = false
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        owner?.parserErrorOccurred(parseError)
    }
}

// MARK: - Controller

@objc(ForgeInstallViewController)
@objcMembers
class ForgeInstallViewController: UITableViewController, UISearchResultsUpdating {
    private var searchController: UISearchController!
    private var searchText: String?
    private var downloadSession: URLSession?
    private var downloadProgressObservation: NSKeyValueObservation?
    private var progressView: UIControl?
    private var currentVendor: String = ""

    private var endpoints: [String: [String: String]] = [:]
    private var visibilityList: [Bool] = []
    private var versionList: [String] = []
    private var forgeList: [[String]] = []
    private var filteredForgeList: [[String]] = []
    private var currentDownloadIndexPath: IndexPath?
    private let stateLock = NSLock()
    private var _isDataLoading = false
    private var isDataLoading: Bool {
        get { return forgeLocked(stateLock) { _isDataLoading } }
        set { forgeLocked(stateLock) { _isDataLoading = newValue } }
    }
    private let dataLock = NSLock()

    // Performance optimizations
    private var searchDebounceTimer: Timer?
    private var displayNameCache: [String: String] = [:]
    // The original touched the cache from the search queue and the main thread without protection
    private let cacheLock = NSLock()
    private let searchQueue = DispatchQueue(label: "com.amethyst.forge.search")

    override func viewDidLoad() {
        super.viewDidLoad()

        if let navigationController = navigationController {
            navigationController.navigationBar.isTranslucent = false
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor.systemBackground
            navigationController.navigationBar.standardAppearance = appearance
            navigationController.navigationBar.compactAppearance = appearance
            navigationController.navigationBar.scrollEdgeAppearance = appearance
        }

        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }

        tableView.contentInsetAdjustmentBehavior = .automatic

        extendedLayoutIncludesOpaqueBars = false
        edgesForExtendedLayout = []

        tableView.register(ForgeVersionCell.self, forCellReuseIdentifier: "ForgeVersionCell")
        tableView.register(MinecraftVersionHeaderView.self, forHeaderFooterViewReuseIdentifier: "MinecraftVersionHeader")

        let segment = UISegmentedControl(items: ["Forge", "NeoForge"])
        segment.selectedSegmentIndex = 0
        segment.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        navigationItem.titleView = segment
        currentVendor = "Forge"

        searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search versions"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshVersions), for: .valueChanged)
        refreshControl = refresh
        tableView.addSubview(refresh)

        _ = dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL)
        if let viewClass = NSClassFromString("WFWorkflowProgressView") as? UIControl.Type {
            let progress = viewClass.init(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
            progress.setValue(view.tintColor, forKey: "resolvedTintColor")
            progress.addTarget(self, action: #selector(actionCancelDownload), for: .touchUpInside)
            progressView = progress
        }

        endpoints = [
            "Forge": [
                "installer": "https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
                "metadata": "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
            ],
            "NeoForge": [
                "installer": "https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
                "metadata": "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
            ]
        ]

        visibilityList = []
        versionList = []
        forgeList = []
        filteredForgeList = []
        isDataLoading = false

        loadMetadata(fromVendor: "Forge")
    }

    deinit {
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = nil
    }

    private func setProgressFraction(_ value: Double) {
        progressView?.setValue(NSNumber(value: value), forKey: "fractionCompleted")
    }

    func actionCancelDownload() {
        if let indexPath = currentDownloadIndexPath {
            resetCellAppearance(indexPath)
            currentDownloadIndexPath = nil
        }

        downloadSession?.invalidateAndCancel()
        showDialog("Download Cancelled", "The download has been cancelled.")
    }

    private func resetCellAppearance(_ indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }

        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator
    }

    func actionClose() {
        navigationController?.dismiss(animated: true, completion: nil)
    }

    func segmentChanged(_ segment: UISegmentedControl) {
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = nil

        if searchController.isActive {
            searchController.dismiss(animated: true, completion: nil)
        }

        let vendor = segment.titleForSegment(at: segment.selectedSegmentIndex) ?? ""
        currentVendor = vendor
        loadMetadata(fromVendor: vendor)
    }

    func refreshVersions() {
        loadMetadata(fromVendor: currentVendor)
    }

    func loadMetadata(fromVendor vendor: String) {
        switchToLoadingState()

        isDataLoading = true

        forgeLocked(dataLock) {
            visibilityList.removeAll()
            versionList.removeAll()
            forgeList.removeAll()
            filteredForgeList.removeAll()
        }
        forgeLocked(cacheLock) {
            displayNameCache.removeAll()
        }

        DispatchQueue.main.async {
            self.tableView.reloadData()
        }

        let metadata = endpoints[vendor]?["metadata"]
        DispatchQueue.global(qos: .default).async {
            let url = metadata.flatMap { URL(string: $0) }
            let parser = url.flatMap { XMLParser(contentsOf: $0) }
            let parserDelegate = ForgeMetadataParserDelegate(owner: self)
            parser?.delegate = parserDelegate

            if !(parser?.parse() ?? false) {
                let message = parser?.parserError?.localizedDescription ?? ""
                DispatchQueue.main.async {
                    self.isDataLoading = false
                    self.refreshControl?.endRefreshing()
                    showDialog(localize("Error"), message)
                    self.actionClose()
                }
            }
            // keeps the delegate alive until parsing is done
            withExtendedLifetime(parserDelegate) {}
        }
    }

    private func switchToLoadingState() {
        let indicator = UIActivityIndicatorView(style: .medium)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: indicator)
        indicator.startAnimating()
        navigationController?.isModalInPresentation = true
    }

    private func switchToReadyState() {
        let indicator = navigationItem.rightBarButtonItem?.customView as? UIActivityIndicatorView
        indicator?.stopAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(actionClose))
        navigationController?.isModalInPresentation = false
        refreshControl?.endRefreshing()
    }

    // MARK: Search Results Updating

    func updateSearchResults(for searchController: UISearchController) {
        if isDataLoading {
            return
        }

        let searchText = searchController.searchBar.text

        searchDebounceTimer?.invalidate()

        searchDebounceTimer = Timer.scheduledTimer(timeInterval: 0.15,
                                                   target: self,
                                                   selector: #selector(performSearch(_:)),
                                                   userInfo: searchText,
                                                   repeats: false)
    }

    func performSearch(_ timer: Timer) {
        let searchText = timer.userInfo as? String
        self.searchText = searchText

        guard let searchText = searchText, searchText.count > 0 else {
            forgeLocked(dataLock) {
                filteredForgeList.removeAll()
                for forgeVersions in forgeList {
                    filteredForgeList.append(forgeVersions)
                }
            }

            DispatchQueue.main.async {
                self.tableView.reloadData()
            }
            return
        }

        searchQueue.async {
            let (forgeListSnapshot, vendor): ([[String]], String) = forgeLocked(self.dataLock) {
                return (self.forgeList, self.currentVendor)
            }

            var newFilteredList: [[String]] = []
            var sectionsWithResults: [Int] = []

            for i in 0..<forgeListSnapshot.count {
                let sectionVersions = forgeListSnapshot[i]
                var filteredSectionVersions: [String] = []

                for version in sectionVersions {
                    let displayName = self.getCachedDisplayName(version, forVendor: vendor)

                    if displayName.localizedCaseInsensitiveContains(searchText) {
                        filteredSectionVersions.append(version)
                    }
                }

                newFilteredList.append(filteredSectionVersions)

                if filteredSectionVersions.count > 0 {
                    sectionsWithResults.append(i)
                }
            }

            DispatchQueue.main.async {
                let oldFilteredList: [[String]] = forgeLocked(self.dataLock) {
                    let old = self.filteredForgeList

                    self.filteredForgeList.removeAll()
                    self.filteredForgeList.append(contentsOf: newFilteredList)

                    for idx in sectionsWithResults {
                        if idx < self.visibilityList.count {
                            self.visibilityList[idx] = true
                        }
                    }
                    return old
                }

                if !self.isFilteredList(oldFilteredList, equalTo: newFilteredList) {
                    self.tableView.reloadData()
                }
            }
        }
    }

    private func isFilteredList(_ list1: [[String]], equalTo list2: [[String]]) -> Bool {
        if list1.count != list2.count { return false }

        for i in 0..<list1.count {
            if list1[i] != list2[i] {
                return false
            }
        }

        return true
    }

    private func getCachedDisplayName(_ version: String, forVendor vendor: String) -> String {
        let cacheKey = "\(vendor)_\(version)"

        let cached: String? = forgeLocked(cacheLock) { displayNameCache[cacheKey] }
        if let cached = cached {
            return cached
        }

        // Compute and cache
        let displayName = getDisplayName(version)
        forgeLocked(cacheLock) { displayNameCache[cacheKey] = displayName }

        return displayName
    }

    // MARK: Version Display Methods

    private func getDisplayName(_ version: String) -> String {
        if currentVendor == "NeoForge" {
            let mcVersion = extractMinecraftVersionFromNeoForgeVersion(version)

            if mcVersion != "Unknown" {
                if isSnapshotVersion(mcVersion) || mcVersion.contains("w") {
                    return "NeoForge \(version) (Snapshot \(mcVersion))"
                } else {
                    return "NeoForge \(version) (Minecraft \(mcVersion))"
                }
            } else {
                return "NeoForge \(version)"
            }
        } else {
            let mcVersion = extractMinecraftVersionFromForgeVersion(version)
            let hyphenRange = forgeHyphenRange(version)

            if hyphenRange.location != NSNotFound && mcVersion != "Unknown" {
                let forgeVersion = (version as NSString).substring(from: hyphenRange.location + 1)

                if isSnapshotVersion(mcVersion) {
                    return "Forge \(forgeVersion) (Snapshot \(mcVersion))"
                } else {
                    return "Forge \(forgeVersion) (Minecraft \(mcVersion))"
                }
            } else {
                return version
            }
        }
    }

    private func extractMinecraftVersionFromForgeVersion(_ version: String) -> String {
        let hyphenRange = forgeHyphenRange(version)
        if hyphenRange.location != NSNotFound {
            let mcPortion = (version as NSString).substring(to: hyphenRange.location)

            if isSnapshotVersion(mcPortion) {
                return mcPortion
            }

            let mcRegex = try? NSRegularExpression(pattern: "^1\\.[0-9]+(\\.[0-9]+)?$", options: [])

            let fullRange = NSRange(location: 0, length: (mcPortion as NSString).length)
            if mcRegex?.firstMatch(in: mcPortion, options: [], range: fullRange) != nil {
                return mcPortion
            }
        }

        return "Unknown"
    }

    private func extractMinecraftVersionFromNeoForgeVersion(_ version: String) -> String {
        /* NeoForge versioning: [MC version without 1.].[NeoForge version][-beta/alpha]
           Example: "21.4.114-beta" for Minecraft 1.21.4
           Special case: "0.25w14craftmine.5-beta" contains snapshot "25w14craftmine" */

        var cleanVersion = version
        let hyphenRange = forgeHyphenRange(version)
        if hyphenRange.location != NSNotFound {
            cleanVersion = (version as NSString).substring(to: hyphenRange.location)
        }

        let snapshotRegex = try? NSRegularExpression(pattern: "(\\d{2}w\\d{2}[a-z]*)", options: .caseInsensitive)

        let cleanNS = cleanVersion as NSString
        if let snapshotMatch = snapshotRegex?.firstMatch(in: cleanVersion, options: [], range: NSRange(location: 0, length: cleanNS.length)) {
            let snapshotVersion = cleanNS.substring(with: snapshotMatch.range)
            return snapshotVersion // Return snapshot version directly
        }

        let components = cleanVersion.components(separatedBy: ".")
        if components.count >= 2 {
            let majorComponent = components[0]
            let minorComponent = components[1]

            if isNumeric(majorComponent) && isNumeric(minorComponent) {
                let mcVersion = "1.\(majorComponent).\(minorComponent)"
                return mcVersion
            }
        }

        let versionRegex = try? NSRegularExpression(pattern: "(\\d+\\.\\d+)", options: [])

        let versionNS = version as NSString
        if let match = versionRegex?.firstMatch(in: version, options: [], range: NSRange(location: 0, length: versionNS.length)) {
            let extractedPart = versionNS.substring(with: match.range)
            return "1.\(extractedPart)"
        }

        return "Unknown"
    }

    private func isSnapshotVersion(_ version: String) -> Bool {
        if version.count == 0 { return false }
        let regex = try? NSRegularExpression(pattern: "(?i)^\\d{2}w\\d{2}[a-z]$", options: [])
        let fullRange = NSRange(location: 0, length: (version as NSString).length)
        return regex?.firstMatch(in: version, options: [], range: fullRange) != nil
    }

    private func getColorForVersionType(_ version: String) -> UIColor {
        if version.contains("recommended") {
            return UIColor.systemGreen
        } else if version.contains("beta") || version.contains("-beta") {
            return UIColor.systemOrange
        } else if version.contains("alpha") || version.contains("-alpha") {
            return UIColor.systemRed
        } else {
            return UIColor.systemBlue // Release version
        }
    }

    private func getLabelForVersionType(_ version: String) -> String {
        if version.contains("recommended") {
            return "Recommended"
        } else if version.contains("beta") || version.contains("-beta") {
            return "Beta"
        } else if version.contains("alpha") || version.contains("-alpha") {
            return "Alpha"
        } else {
            return "Release"
        }
    }

    private func isNumeric(_ string: String) -> Bool {
        if string.count == 0 { return false }

        let nonNumbers = CharacterSet.decimalDigits.inverted
        return string.rangeOfCharacter(from: nonNumbers) == nil
    }

    // MARK: UITableViewDataSource

    /// The version string at an index path in the list currently shown (caller holds dataLock)
    private func versionLocked(at indexPath: IndexPath) -> String? {
        if searchController.isActive {
            guard indexPath.section < filteredForgeList.count,
                  indexPath.row < filteredForgeList[indexPath.section].count else { return nil }
            return filteredForgeList[indexPath.section][indexPath.row]
        } else {
            guard indexPath.section < forgeList.count,
                  indexPath.row < forgeList[indexPath.section].count else { return nil }
            return forgeList[indexPath.section][indexPath.row]
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        if isDataLoading {
            return 0
        }

        return forgeLocked(dataLock) { versionList.count }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isDataLoading {
            return 0
        }

        return forgeLocked(dataLock) { () -> Int in
            if section >= visibilityList.count {
                return 0
            }

            var rows = 0

            if visibilityList[section] {
                if searchController.isActive {
                    if section < filteredForgeList.count {
                        rows = filteredForgeList[section].count
                    }
                } else {
                    if section < forgeList.count {
                        rows = forgeList[section].count
                    }
                }
            }

            return rows
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: "MinecraftVersionHeader") as? MinecraftVersionHeaderView else {
            return nil
        }

        if isDataLoading {
            headerView.titleLabel.text = "Loading..."
            headerView.isExpanded = false
            headerView.expandCollapseButton.tag = section
            headerView.expandCollapseButton.removeTarget(nil, action: nil, for: .touchUpInside)
            return headerView
        }

        let state: (mcVersion: String, expanded: Bool)? = forgeLocked(dataLock) {
            if section >= versionList.count || versionList.count == 0 {
                return nil
            }
            let expanded = section < visibilityList.count ? visibilityList[section] : false
            return (versionList[section], expanded)
        }

        guard let (mcVersion, expanded) = state else {
            headerView.titleLabel.text = "Loading..."
            headerView.isExpanded = false
            headerView.expandCollapseButton.tag = section

            headerView.expandCollapseButton.removeTarget(nil, action: nil, for: .touchUpInside)
            return headerView
        }

        if mcVersion.hasPrefix("1.") {
            headerView.titleLabel.text = "Minecraft \(mcVersion)"
        } else {
            headerView.titleLabel.text = mcVersion
        }

        headerView.isExpanded = expanded

        headerView.expandCollapseButton.tag = section

        headerView.expandCollapseButton.addTarget(self, action: #selector(toggleSection(_:)), for: .touchUpInside)

        return headerView
    }

    func toggleSection(_ sender: UIButton) {
        if isDataLoading {
            return
        }

        let section = sender.tag

        let toggled: Bool = forgeLocked(dataLock) {
            if section >= 0 && section < visibilityList.count && versionList.count > section {
                visibilityList[section] = !visibilityList[section]
                return true
            }
            return false
        }

        if toggled {
            tableView.reloadSections(IndexSet(integer: section), with: .fade)
        }
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 60.0
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 56.0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ForgeVersionCell", for: indexPath) as? ForgeVersionCell
            ?? ForgeVersionCell(style: .default, reuseIdentifier: "ForgeVersionCell")

        if isDataLoading {
            cell.versionLabel.text = "Loading..."
            cell.subtitleLabel.text = ""
            cell.accessoryType = .none
            return cell
        }

        let found: (version: String, vendor: String)? = forgeLocked(dataLock) {
            guard let version = versionLocked(at: indexPath) else { return nil }
            return (version, currentVendor)
        }

        guard let (version, vendor) = found else {
            cell.versionLabel.text = "Loading..."
            cell.subtitleLabel.text = ""
            cell.accessoryType = .none
            return cell
        }

        // Use cached display name for better performance
        let displayName = getCachedDisplayName(version, forVendor: vendor)
        cell.versionLabel.text = displayName

        let typeLabel = getLabelForVersionType(version)
        let typeColor = getColorForVersionType(version)
        cell.subtitleLabel.text = typeLabel
        cell.subtitleLabel.textColor = typeColor

        cell.accessoryType = .disclosureIndicator

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if isDataLoading {
            return
        }

        let selected: String? = forgeLocked(dataLock) { versionLocked(at: indexPath) }
        guard let versionString = selected else {
            return
        }

        currentDownloadIndexPath = indexPath

        tableView.allowsSelection = false
        switchToLoadingState()
        setProgressFraction(0)

        let cell = tableView.cellForRow(at: indexPath)
        cell?.accessoryView = progressView
        cell?.accessoryType = .none

        let installerTemplate = endpoints[currentVendor]?["installer"] ?? ""
        let jarURL = String(format: installerTemplate, versionString)
        let outPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("tmp.jar")
        NSDebugLog("[\(currentVendor) Installer] Downloading \(jarURL)")

        // AFURLSessionManager replaced by a plain URLSession, same download-to-file flow
        let session = URLSession(configuration: URLSessionConfiguration.default)
        downloadSession = session
        let request = URLRequest(url: URL(string: jarURL) ?? URL(fileURLWithPath: "/"))
        let downloadTask = session.downloadTask(with: request) { [weak self] location, _, error in
            var resultError = error
            if resultError == nil, let location = location {
                // destination block of the original: clear the old file, put the download there
                try? FileManager.default.removeItem(atPath: outPath)
                do {
                    try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: outPath))
                } catch let moveError {
                    resultError = moveError
                }
            }
            let finalError = resultError

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.downloadProgressObservation = nil
                tableView.allowsSelection = true
                self.resetCellAppearance(indexPath)
                self.currentDownloadIndexPath = nil

                if let finalError = finalError {
                    if (finalError as NSError).code != NSURLErrorCancelled {
                        NSDebugLog("Error: \(finalError)")
                        showDialog(localize("Error"), finalError.localizedDescription)
                    }
                    self.switchToReadyState()
                    return
                }

                showDialog("Download Complete",
                           "\(self.currentVendor) installer will now run. After installation completes, you will need to restart the app.")

                let navVC = (self.presentingViewController as? UISplitViewController)?.viewControllers[1] as? LauncherNavigationController

                // Dismiss search controller first if it's active, then dismiss main view controller
                if self.searchController.isActive {
                    self.searchController.dismiss(animated: false) {
                        self.dismiss(animated: true) {
                            navVC?.enterModInstallerWithPath(outPath, hitEnterAfterWindowShown: true)
                        }
                    }
                } else {
                    self.dismiss(animated: true) {
                        navVC?.enterModInstallerWithPath(outPath, hitEnterAfterWindowShown: true)
                    }
                }
            }
        }

        downloadProgressObservation = downloadTask.progress.observe(\.fractionCompleted, options: []) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                self?.setProgressFraction(fraction)
            }
        }

        DispatchQueue.global(qos: .default).async {
            downloadTask.resume()
        }
    }

    fileprivate func addVersionToList(_ version: String) {
        if version.count == 0 {
            return
        }

        dataLock.lock()
        defer { dataLock.unlock() }

        if currentVendor == "NeoForge" {
            let skipPatterns = [
                "sources", "userdev", "javadoc", "universal", "slim",
                "-javadoc", "-sources", "-all", "-changelog",
                "-installer-win", "-mdk"
            ]

            for pattern in skipPatterns {
                if version.contains(pattern) {
                    NSLog("[ForgeInstall] Skipping problematic NeoForge version: %@", version)
                    return
                }
            }

            let minecraftVersion = extractMinecraftVersionFromNeoForgeVersion(version)

            if minecraftVersion == "Unknown" {
                NSLog("[ForgeInstall] Skipping NeoForge version with unknown MC version: %@", version)
                return
            }

            var sectionIndex = versionList.firstIndex(of: minecraftVersion)

            if sectionIndex == nil {
                versionList.append(minecraftVersion)
                visibilityList.append(false) // Start collapsed
                forgeList.append([])
                sectionIndex = versionList.count - 1
            }

            if let index = sectionIndex, !forgeList[index].contains(version) {
                forgeList[index].append(version)
                NSLog("[ForgeInstall] Added NeoForge %@ to %@ section", version, minecraftVersion)
            }
        } else {
            if !version.contains("-") {
                NSLog("[ForgeInstall] Skipping invalid Forge version format: %@", version)
                return
            }

            let skipPatterns = [
                "mdk", "userdev", "javadoc", "src", "sources", "universal",
                "-all", "-changelog", "-client", "-server", "-launcher"
            ]

            for pattern in skipPatterns {
                if version.contains(pattern) {
                    NSLog("[ForgeInstall] Skipping problematic Forge version: %@", version)
                    return
                }
            }

            let hyphenRange = forgeHyphenRange(version)
            if hyphenRange.location == NSNotFound {
                return
            }

            let minecraftVersion = (version as NSString).substring(to: hyphenRange.location)

            var sectionIndex = versionList.firstIndex(of: minecraftVersion)

            if sectionIndex == nil {
                versionList.append(minecraftVersion)
                visibilityList.append(false)
                forgeList.append([])
                sectionIndex = versionList.count - 1
            }

            if let index = sectionIndex, !forgeList[index].contains(version) {
                forgeList[index].append(version)
                NSLog("[ForgeInstall] Added Forge %@ to %@ section", version, minecraftVersion)
            }
        }
    }

    // MARK: XML parser callbacks (forwarded by ForgeMetadataParserDelegate)

    fileprivate func parserDidEndDocument() {
        DispatchQueue.main.async {
            self.dataLock.lock()

            let vendor = self.currentVendor

            var indices = Array(0..<self.versionList.count)
            let versions = self.versionList
            // Ascending means "comes first": higher minor, then higher patch first; ties keep their order
            indices = indices.enumerated().sorted { lhs, rhs in
                let va = versions[lhs.element]
                let vb = versions[rhs.element]

                let pa = va.components(separatedBy: ".")
                let pb = vb.components(separatedBy: ".")
                let aMinor = pa.count > 1 ? forgeIntegerValue(pa[1]) : 0
                let bMinor = pb.count > 1 ? forgeIntegerValue(pb[1]) : 0
                if aMinor != bMinor { return aMinor > bMinor }
                let aPatch = pa.count > 2 ? forgeIntegerValue(pa[2]) : 0
                let bPatch = pb.count > 2 ? forgeIntegerValue(pb[2]) : 0
                if aPatch != bPatch { return aPatch > bPatch }
                return lhs.offset < rhs.offset
            }.map { $0.element }

            var newVisibility: [Bool] = []
            var newVersionList: [String] = []
            var newForgeList: [[String]] = []
            for idx in indices {
                newVisibility.append(self.visibilityList[idx])
                newVersionList.append(self.versionList[idx])
                newForgeList.append(self.forgeList[idx])
            }
            self.visibilityList = newVisibility
            self.versionList = newVersionList
            self.forgeList = newForgeList

            for sectionIndex in 0..<self.forgeList.count {
                let sorted = self.forgeList[sectionIndex].enumerated().sorted { lhsItem, rhsItem in
                    let lhs = lhsItem.element
                    let rhs = rhsItem.element
                    if vendor == "Forge" {
                        let dashL = forgeHyphenRange(lhs)
                        let dashR = forgeHyphenRange(rhs)
                        let lv = dashL.location != NSNotFound ? (lhs as NSString).substring(from: dashL.location + 1) : lhs
                        let rv = dashR.location != NSNotFound ? (rhs as NSString).substring(from: dashR.location + 1) : rhs
                        let lp = lv.components(separatedBy: ".")
                        let rp = rv.components(separatedBy: ".")
                        let lA = lp.count > 0 ? forgeIntegerValue(lp[0]) : 0
                        let rA = rp.count > 0 ? forgeIntegerValue(rp[0]) : 0
                        if lA != rA { return lA > rA }
                        let lB = lp.count > 1 ? forgeIntegerValue(lp[1]) : 0
                        let rB = rp.count > 1 ? forgeIntegerValue(rp[1]) : 0
                        if lB != rB { return lB > rB }
                        let lC = lp.count > 2 ? forgeIntegerValue(lp[2]) : 0
                        let rC = rp.count > 2 ? forgeIntegerValue(rp[2]) : 0
                        if lC != rC { return lC > rC }
                        return lhsItem.offset < rhsItem.offset
                    } else {
                        let lClean = lhs.replacingOccurrences(of: "-beta", with: "")
                        let rClean = rhs.replacingOccurrences(of: "-beta", with: "")
                        let lc = lClean.components(separatedBy: ".")
                        let rc = rClean.components(separatedBy: ".")
                        let lBuild = lc.count > 2 ? forgeIntegerValue(lc[2]) : 0
                        let rBuild = rc.count > 2 ? forgeIntegerValue(rc[2]) : 0
                        if lBuild != rBuild { return lBuild > rBuild }

                        return lhsItem.offset < rhsItem.offset
                    }
                }.map { $0.element }
                self.forgeList[sectionIndex] = sorted
            }

            self.filteredForgeList.removeAll()
            for forgeVersions in self.forgeList {
                self.filteredForgeList.append(forgeVersions)
            }

            self.dataLock.unlock()

            self.isDataLoading = false

            self.switchToReadyState()
            self.tableView.reloadData()

            if self.versionList.count > 0 {
                self.tableView.setContentOffset(CGPoint.zero, animated: true)
            }
        }
    }

    fileprivate func parserErrorOccurred(_ parseError: Error) {
        DispatchQueue.main.async {
            self.isDataLoading = false

            self.refreshControl?.endRefreshing()
            showDialog("Error Loading Versions", parseError.localizedDescription)
            self.switchToReadyState()
        }
    }
}
