import UIKit

@objc(FabricInstallViewController)
@objcMembers
class FabricInstallViewController: PLPrefTableViewController {
    private var endpoints: [AnyHashable: Any] = [:]
    private var localKVO: [String: Any] = [:]
    // Loader metadata
    private var loaderMetadata: [Any] = []
    private var loaderList: [String] = []
    // Game metadata
    private var versionMetadata: [Any] = []
    private var versionList: [String] = []

    // Row numbers in prefContents[0]
    private let gameVersionRow = 1
    private let loaderVersionRow = 4

    override func viewDidLoad() {
        // Setup navigation bar
        title = localize("profile.title.install_fabric_quilt")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(actionDone(_:)))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(actionClose))

        // Setup appearance
        prefSectionsVisible = true

        // Setup preference getter and setter
        localKVO = [
            "gameVersion": "1.20.1",
            "loaderVendor": "Fabric",
            "loaderVersion": "0.14.22"
        ]
        getPreference = { [weak self] _, key in
            return self?.localKVO[key]
        }
        setPreference = { [weak self] _, key, value in
            self?.localKVO[key] = value
        }

        versionList = []
        loaderList = []
        prefContents = [
            [
                PrefItem(kind: .custom,
                         key: "gameType",
                         title: "preference.profile.title.version_type",
                         icon: "ladybug",
                         pickList: [localize("Release"), localize("Snapshot")],
                         customCreate: pickSegmentCreator { [weak self] type in
                             self?.changeVersionType(to: type)
                         }),
                PrefItem(kind: .pickField,
                         key: "gameVersion",
                         title: "preference.profile.title.version",
                         icon: "archivebox",
                         pickKeys: versionList,
                         pickList: versionList),
                PrefItem(kind: .custom,
                         key: "loaderVendor",
                         title: "preference.profile.title.loader_vendor",
                         icon: "folder.badge.gearshape",
                         pickList: ["Fabric", "Quilt"],
                         customCreate: pickSegmentCreator { [weak self] vendor in
                             self?.fetchVersionEndpoints(vendor)
                         }),
                PrefItem(kind: .custom,
                         key: "loaderType",
                         title: "preference.profile.title.loader_type",
                         icon: "ladybug",
                         pickList: [localize("Release"), "Unstable"],
                         customCreate: pickSegmentCreator { [weak self] type in
                             self?.changeLoaderType(to: type)
                         }),
                PrefItem(kind: .pickField,
                         key: "loaderVersion",
                         title: "preference.profile.title.loader_version",
                         icon: "doc.badge.gearshape",
                         pickKeys: loaderList,
                         pickList: loaderList)
            ]
        ]

        // Ensure views are loaded here
        super.viewDidLoad()

        // Init endpoint info
        endpoints = FabricUtils.endpoints() ?? [:]
        fetchVersionEndpoints(0)
    }

    /// Was the `typePickSegment` block: a segmented control over the row's pickList
    private func pickSegmentCreator(action: @escaping (Int) -> Void) -> (UITableViewCell, String, String, PrefItem) -> Void {
        return { [weak self] cell, _, key, item in
            let view = UISegmentedControl(items: item.pickList)
            view.addAction(UIAction { [weak self, weak view] _ in
                guard let self = self, let view = view else { return }
                self.segmentChanged(view, key: key, action: action)
            }, for: .valueChanged)
            if view.selectedSegmentIndex == UISegmentedControl.noSegment {
                view.selectedSegmentIndex = 0
            }
            cell.accessoryView = view
        }
    }

    private func segmentChanged(_ sender: UISegmentedControl, key: String, action: (Int) -> Void) {
        localKVO[key] = sender.titleForSegment(at: sender.selectedSegmentIndex)
        localKVO[key + "_index"] = NSNumber(value: sender.selectedSegmentIndex)
        action(sender.selectedSegmentIndex)
    }

    private func currentEndpoint() -> [AnyHashable: Any] {
        let vendor = localKVO["loaderVendor"] as? String ?? ""
        return endpoints[vendor] as? [AnyHashable: Any] ?? [:]
    }

    func fetchVersionEndpoints(_ type: Int) {
        // Fetch version
        var errorShown = false
        let errorCallback: (Error?) -> Void = { [weak self] error in
            if !errorShown {
                errorShown = true
                NSDebugLog("Error: \(String(describing: error))")
                showDialog(localize("Error"), error?.localizedDescription ?? "")
                self?.actionClose()
            }
        }
        let endpoint = currentEndpoint()
        let vendor = localKVO["loaderVendor"] as? String ?? ""
        httpGetJSON(endpoint["game"] as? String ?? "") { [weak self] response, error in
            guard let self = self else { return }
            guard error == nil, let list = response as? [Any] else { errorCallback(error); return }
            NSDebugLog("[\(vendor) Installer] Got \(list.count) game versions")
            self.versionMetadata = list
            self.changeVersionType(to: prefInt(self.localKVO["gameType_index"]))
        }
        httpGetJSON(endpoint["loader"] as? String ?? "") { [weak self] response, error in
            guard let self = self else { return }
            guard error == nil, let list = response as? [Any] else { errorCallback(error); return }
            NSDebugLog("[\(vendor) Installer] Got \(list.count) loader versions")
            self.loaderMetadata = list
            self.changeLoaderType(to: prefInt(self.localKVO["loaderType_index"]))
        }
    }

    func actionClose() {
        navigationController?.dismiss(animated: true)
    }

    func actionDone(_ sender: UIBarButtonItem) {
        sender.isEnabled = false

        let endpoint = currentEndpoint()
        let vendor = localKVO["loaderVendor"] as? String ?? ""
        let path = String(format: endpoint["json"] as? String ?? "",
                          localKVO["gameVersion"] as? String ?? "",
                          localKVO["loaderVersion"] as? String ?? "")
        NSDebugLog("[\(vendor) Installer] Downloading \(path)")

        httpGetJSON(path) { [weak self] response, error in
            sender.isEnabled = true
            guard error == nil, let dict = response as? [String: Any] else {
                NSDebugLog("Error: \(String(describing: error))")
                showDialog(localize("Error"), error?.localizedDescription ?? "")
                return
            }

            let versionId = dict["id"] as? String ?? ""
            let jsonPath = "\(gameDir)/versions/\(versionId)/\(versionId).json"
            try? FileManager.default.createDirectory(atPath: (jsonPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: nil)
            if let saveError = saveJSONToFile(dict, jsonPath) {
                showDialog(localize("Error"), saveError.localizedDescription)
            } else {
                localVersionList?.add(["id": versionId, "type": "custom"] as NSDictionary)
                // Jump to the profile editor
                let vc = LauncherProfileEditorViewController()
                vc.profile = NSMutableDictionary(dictionary: [
                    "icon": endpoint["icon"] as? String ?? "",
                    "name": versionId,
                    "lastVersionId": versionId
                ])
                self?.navigationController?.pushViewController(vc, animated: true)
            }
        }
    }

    private func changeType(toStable stable: Bool, list: inout [String], metadata: [Any], row: Int, key: String) {
        list.removeAll()

        for case let version as NSDictionary in metadata {
            let name = version["version"] as? String ?? ""
            if let stableValue = version["stable"] {
                // Fabric: has stable key
                if prefBool(stableValue) != stable { continue }
            } else {
                // Quilt: has beta in the version name
                if name.contains("beta") == stable { continue }
            }
            list.append(name)
        }
        localKVO[key] = list.first
        // The pick rows read their lists when they are built, so hand them the new ones
        if !prefContents.isEmpty && row < prefContents[0].count {
            prefContents[0][row].pickKeys = list
            prefContents[0][row].pickList = list
        }
        tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
    }

    func changeLoaderType(to type: Int) {
        var list = loaderList
        changeType(toStable: type == 0, list: &list, metadata: loaderMetadata, row: loaderVersionRow, key: "loaderVersion")
        loaderList = list
    }

    func changeVersionType(to type: Int) {
        var list = versionList
        changeType(toStable: type == 0, list: &list, metadata: versionMetadata, row: gameVersionRow, key: "gameVersion")
        versionList = list
    }
}
