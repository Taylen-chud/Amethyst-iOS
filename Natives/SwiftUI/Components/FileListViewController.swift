import UIKit

/// Lists the `.json` files of a directory (control layouts) and lets the user pick or delete one.
@objc(FileListViewController)
@objcMembers
class FileListViewController: UITableViewController {
    var listPath: String!
    /// Called with the full path of a file that was deleted
    var whenDelete: ((String) -> Void)?
    /// Called with the file name without extension
    var whenItemSelected: ((String) -> Void)?

    private var fileList: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        fileList.removeAll()

        // List files
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: listPath)) ?? []
        for file in files {
            let path = (listPath as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            if !isDir.boolValue && file.hasSuffix(".json") {
                fileList.append((file as NSString).deletingPathExtension)
            }
        }

        tableView.separatorStyle = .singleLine
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return fileList.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .default, reuseIdentifier: "cell")

        cell.textLabel?.text = fileList[indexPath.row]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        dismiss(animated: true)

        whenItemSelected?(fileList[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let name = fileList[indexPath.row]
            let path = "\(listPath ?? "")/\(name).json"
            whenDelete?(path)
            try? FileManager.default.removeItem(atPath: path)
            fileList.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .fade)
        }
    }
}
