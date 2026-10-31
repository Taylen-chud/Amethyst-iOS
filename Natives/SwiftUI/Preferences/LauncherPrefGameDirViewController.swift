import UIKit

/// `-[NSFileManager nr_getAllocatedSize:ofDirectoryAtURL:error:]`, called through its IMP so the call does not
/// depend on how Swift renames that selector.
private func gameDirAllocatedSize(ofDirectory directory: String) -> UInt64 {
    var size: UInt64 = 0
    let selector = NSSelectorFromString("nr_getAllocatedSize:ofDirectoryAtURL:error:")
    let manager = FileManager.default
    guard manager.responds(to: selector), let imp = manager.method(for: selector) else { return 0 }
    typealias SizeFunc = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<UInt64>, NSURL, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
    _ = unsafeBitCast(imp, to: SizeFunc.self)(manager, selector, &size, NSURL(fileURLWithPath: directory), nil)
    return size
}

@objc(LauncherPrefGameDirViewController)
@objcMembers
class LauncherPrefGameDirViewController: UITableViewController, UITextFieldDelegate {

    private var array: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = localize("preference.title.game_directory")

        array = ["default"]

        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.keyboardDismissMode = .interactive
        tableView.sectionFooterHeight = 50

        let path = "\(envString("AME_HOME") ?? "")/instances"

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        var isDir: ObjCBool = false
        for file in files {
            // Like the Obj-C version this asks about the instances folder itself, not about `file`
            fm.fileExists(atPath: path, isDirectory: &isDir)
            if isDir.boolValue && file != "default" {
                array.append(file)
            }
        }
    }

    func changeSelection(to name: String) {
        if getenv("DEMO_LOCK") != nil { return }

        setPrefObject("general.game_directory", name)
        let multidirPath = "\(envString("AME_HOME") ?? "")/instances/\(name)"
        let lasmPath = envString("GAME_DIR") ?? ""
        try? FileManager.default.removeItem(atPath: lasmPath)
        try? FileManager.default.createSymbolicLink(atPath: lasmPath, withDestinationPath: multidirPath)
        _ = FileManager.default.changeCurrentDirectoryPath(lasmPath)
        toggleIsolatedPref(false)
        (navigationController as? LauncherNavigationController)?.reloadProfileList()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return array.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: "cell") {
            cell = reused
        } else {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
            let field = UITextField(frame: CGRect(x: 20, y: 10, width: (cell.bounds.size.width - 40) / 2, height: cell.bounds.size.height - 20))
            field.addTarget(field, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.autoresizingMask = .flexibleWidth
            field.delegate = self
            field.returnKeyType = .done
            field.isUserInteractionEnabled = indexPath.row != 0
            cell.contentView.addSubview(field)
            cell.detailTextLabel?.text = "..."
        }
        let name = array[indexPath.row]
        let view = cell.contentView.subviews.first as? UITextField
        view?.placeholder = name
        view?.text = name
        cell.textLabel?.isHidden = true
        cell.textLabel?.text = view?.text

        // Calculate the instance size
        DispatchQueue.global().async { [weak cell] in
            let directory = "\(envString("AME_HOME") ?? "")/instances/\(name)"
            let folderSize = gameDirAllocatedSize(ofDirectory: directory)
            DispatchQueue.main.async {
                cell?.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount: Int64(bitPattern: folderSize), countStyle: .memory)
            }
        }

        if (getPrefObject("general.game_directory") as? String) == name {
            cell.accessoryType = .checkmark
        } else {
            cell.accessoryType = .none
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let view = UITextField()
        view.addTarget(view, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.delegate = self
        view.placeholder = localize("preference.multidir.add_directory")
        view.returnKeyType = .done
        return view
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectDirectory(at: indexPath)
    }

    private func selectDirectory(at indexPath: IndexPath) {
        changeSelection(to: array[indexPath.row])
        tableView.deselectRow(at: indexPath, animated: false)
        for i in 0..<array.count {
            let cell = self.tableView.cellForRow(at: IndexPath(row: i, section: 0))
            if i == indexPath.row {
                cell?.accessoryType = .checkmark
            } else {
                cell?.accessoryType = .none
            }
        }
    }

    private func createOpenScheme(_ scheme: String, at directory: String) -> UIActionHandler {
        return { _ in
            if let url = URL(string: "\(scheme)://\(directory)") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let menuItems: [UIMenuElement]
        var openItems: [UIMenuElement] = []

        let directory = "\(envString("AME_HOME") ?? "")/instances/\(array[indexPath.row])"
        let apps: [(key: String, title: String)] = [
            ("shareddocuments", "Files"),
            ("filza", "Filza"),
            ("santander", "Santander"),
        ]
        for app in apps {
            if let url = URL(string: "\(app.key)://"), UIApplication.shared.canOpenURL(url) {
                openItems.append(UIAction(title: app.title, image: nil, identifier: nil,
                                          handler: createOpenScheme(app.key, at: directory)))
            }
        }
        let open = UIMenu(title: "", image: nil, identifier: nil, options: .displayInline, children: openItems)

        if indexPath.row == 0 {
            // You can't delete or rename the default instance, though there will be a reset action (TODO)
            menuItems = [open]
        } else {
            let rename = UIAction(title: localize("Rename"),
                                  image: UIImage(systemName: "pencil"),
                                  identifier: nil) { [weak self] _ in
                guard let self = self else { return }
                let view = self.tableView.cellForRow(at: indexPath)
                _ = view?.contentView.subviews.first?.becomeFirstResponder()
            }

            let delete = UIAction(title: localize("Delete"),
                                  image: UIImage(systemName: "trash"),
                                  identifier: nil) { [weak self] _ in
                self?.actionDelete(at: indexPath)
            }
            delete.attributes = .destructive

            menuItems = [open, rename, delete]
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self, indexPath.row < self.array.count else { return nil }
            return UIMenu(title: self.array[indexPath.row], children: menuItems)
        }
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            actionDelete(at: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        if indexPath.row == 0 {
            // TODO: Reset action?
            return .none
        } else {
            return .delete
        }
    }

    private func actionDelete(at indexPath: IndexPath) {
        let view = tableView.cellForRow(at: indexPath)
        let title = localize("preference.title.confirm")
        let message = String(format: localize("preference.title.confirm.delete_game_directory"), array[indexPath.row])
        let confirmAlert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        confirmAlert.popoverPresentationController?.sourceView = view
        confirmAlert.popoverPresentationController?.sourceRect = view?.bounds ?? .zero
        let ok = UIAlertAction(title: localize("OK"), style: .destructive) { [weak self] _ in
            guard let self = self, indexPath.row < self.array.count else { return }
            let directory = "\(envString("AME_HOME") ?? "")/instances/\(self.array[indexPath.row])"
            do {
                try FileManager.default.removeItem(atPath: directory)
                if (getPrefObject("general.game_directory") as? String) == self.array[indexPath.row] {
                    self.changeSelection(to: self.array[0])
                    self.tableView.cellForRow(at: IndexPath(row: 0, section: 0))?.accessoryType = .checkmark
                }
                self.array.remove(at: indexPath.row)
                self.tableView.deleteRows(at: [indexPath], with: .automatic)
            } catch {
                showDialog(localize("Error"), error.localizedDescription)
            }
        }
        let cancel = UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil)
        confirmAlert.addAction(cancel)
        confirmAlert.addAction(ok)
        present(confirmAlert, animated: true)
    }

    func dismissModalViewController() {
        navigationController?.dismiss(animated: true)
    }

    // MARK: UITextField

    func textFieldDidEndEditing(_ sender: UITextField) {
        let isFooterView = sender.superview == tableView
        if !sender.hasText || sender.text == sender.placeholder {
            if isFooterView {
                return
            }
            sender.text = sender.placeholder
            return
        }

        var error: Error?
        let text = sender.text ?? ""
        let home = envString("AME_HOME") ?? ""

        let dest = "\(home)/instances/\(text)"
        if isFooterView {
            do {
                try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: false, attributes: nil)
            } catch let e {
                error = e
            }
        } else {
            let source = "\(home)/instances/\(sender.placeholder ?? "")"
            do {
                try FileManager.default.moveItem(atPath: source, toPath: dest)
            } catch let e {
                error = e
            }
        }

        if error == nil {
            changeSelection(to: text)
            if isFooterView {
                let indexPath = IndexPath(row: array.count, section: 0)
                array.append(text)
                tableView.beginUpdates()
                tableView.insertRows(at: [indexPath], with: .automatic)
                tableView.endUpdates()
                selectDirectory(at: indexPath)
                // Clear text
                sender.text = ""
            } else {
                guard let index = array.firstIndex(of: sender.placeholder ?? "") else { return }
                sender.placeholder = text
                array[index] = text
                let indexPath = IndexPath(row: index, section: 0)
                selectDirectory(at: indexPath)
            }
        } else {
            // Restore to the previous name if we encounter an error
            if !isFooterView {
                sender.text = sender.placeholder
            }
            showDialog(localize("Error"), error?.localizedDescription ?? "")
        }
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        textField.invalidateIntrinsicContentSize()
        var frame = textField.frame
        frame.size.width = max(50, textField.intrinsicContentSize.width + 10)
        textField.frame = frame
        return true
    }
}
