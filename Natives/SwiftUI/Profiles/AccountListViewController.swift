import UIKit
import AuthenticationServices

/// Calls `-[target selectorName:]` with an `(id status, BOOL success)` block, by selector, because the
/// Swift spelling of `-loginWithCallback:` / `-refreshTokenWithCallback:` is easy to get wrong.
private func callAuthenticator(_ target: AnyObject, _ selectorName: String, callback: @escaping (Any?, Bool) -> Void) {
    let block: @convention(block) (Any?, Bool) -> Void = { status, success in
        callback(status, success)
    }
    _ = target.perform(NSSelectorFromString(selectorName), with: unsafeBitCast(block, to: AnyObject.self))
}

@objc(AccountListViewController)
@objcMembers
class AccountListViewController: UITableViewController, UIPopoverPresentationControllerDelegate, ASWebAuthenticationPresentationContextProviding {
    var whenDelete: ((String?) -> Void)?
    var whenItemSelected: (() -> Void)?

    private var accountList: [NSMutableDictionary] = []
    private var authVC: ASWebAuthenticationSession?

    override func viewDidLoad() {
        super.viewDidLoad()

        accountList.removeAll()

        // List accounts
        let listPath = "\(envString("AME_HOME") ?? "")/accounts"
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: listPath)) ?? []
        for file in files {
            let path = (listPath as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            if !isDir.boolValue && file.hasSuffix(".json"), let account = parseJSONFromFile(path) {
                accountList.append(account)
            }
        }

        tableView.separatorStyle = .singleLine
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return accountList.count + 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "cell")

        if indexPath.row == accountList.count {
            cell.imageView?.image = UIImage(named: "IconAdd")
            cell.textLabel?.text = localize("login.option.add")
            return cell
        }

        let selected = accountList[indexPath.row]
        let username = selected["username"] as? String
        // By default, display the saved username
        cell.textLabel?.text = username
        if let username = username, username.hasPrefix("Demo.") {
            // Remove the prefix "Demo."
            cell.textLabel?.text = String(username.dropFirst(5))
            cell.detailTextLabel?.text = localize("login.option.demo")
        } else if selected["xboxGamertag"] == nil {
            cell.detailTextLabel?.text = localize("login.option.local")
        } else {
            // Display the Xbox gamertag for online accounts
            cell.detailTextLabel?.text = selected["xboxGamertag"] as? String
        }

        cell.imageView?.contentMode = .center
        let picURL = (selected["profilePicURL"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "\\/", with: "/")) }
        cell.imageView?.setRemoteImage(picURL, placeholder: UIImage(named: "DefaultAccount"))

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let cell = tableView.cellForRow(at: indexPath) else { return }

        if indexPath.row == accountList.count {
            actionAddAccount(cell)
            return
        }

        isModalInPresentation = true
        tableView.isUserInteractionEnabled = false
        addActivityIndicator(to: cell)

        let name = accountList[indexPath.row]["username"] as? String ?? ""
        let authenticator = (BaseAuthenticator.self as AnyObject).perform(NSSelectorFromString("loadSavedName:"), with: name)?.takeUnretainedValue()
        if let authenticator = authenticator {
            callAuthenticator(authenticator, "refreshTokenWithCallback:") { [weak self] status, success in
                DispatchQueue.main.async {
                    self?.callbackMicrosoftAuth(status, success: success, for: cell)
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            // TODO: invalidate token

            let account = accountList[indexPath.row]
            let str = account["username"] as? String ?? ""
            let path = "\(envString("AME_HOME") ?? "")/accounts/\(str).json"
            whenDelete?(str)
            if let xuid = account["xuid"] as? String {
                _ = (MicrosoftAuthenticator.self as AnyObject).perform(NSSelectorFromString("clearTokenDataOfProfile:"), with: xuid)
            }
            try? FileManager.default.removeItem(atPath: path)
            accountList.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .fade)
        }
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        if indexPath.row == accountList.count {
            return .none
        } else {
            return .delete
        }
    }

    func parseQueryItems(_ url: String) -> [String: String] {
        var result: [String: String] = [:]
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        for item in queryItems {
            if let value = item.value {
                result[item.name] = value
            }
        }
        return result
    }

    func actionAddAccount(_ sender: UITableViewCell) {
        let picker = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let actionMicrosoft = UIAlertAction(title: localize("login.option.microsoft"), style: .default) { [weak self] _ in
            self?.actionLoginMicrosoft(sender)
        }
        picker.addAction(actionMicrosoft)
        let actionLocal = UIAlertAction(title: localize("login.option.local"), style: .default) { [weak self] _ in
            self?.actionLoginLocal(sender)
        }
        picker.addAction(actionLocal)
        let cancel = UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil)
        picker.addAction(cancel)

        picker.popoverPresentationController?.sourceView = sender
        picker.popoverPresentationController?.sourceRect = sender.bounds

        present(picker, animated: true)
    }

    func actionLoginLocal(_ sender: UIView) {
        if getPrefBool("warnings.local_warn") {
            setPrefBool("warnings.local_warn", false)
            let alert = UIAlertController(title: localize("login.warn.title.localmode"), message: localize("login.warn.message.localmode"), preferredStyle: .actionSheet)
            alert.popoverPresentationController?.sourceView = sender
            alert.popoverPresentationController?.sourceRect = sender.bounds
            let ok = UIAlertAction(title: localize("OK"), style: .default) { [weak self] _ in
                self?.actionLoginLocal(sender)
            }
            alert.addAction(ok)
            present(alert, animated: true)
            return
        }
        let controller = UIAlertController(title: localize("Sign in"), message: localize("login.option.local"), preferredStyle: .alert)
        controller.addTextField { textField in
            textField.placeholder = localize("login.alert.field.username")
            textField.clearButtonMode = .whileEditing
            textField.borderStyle = .roundedRect
        }
        controller.addAction(UIAlertAction(title: localize("OK"), style: .default) { [weak self, weak controller] _ in
            guard let self = self, let controller = controller else { return }
            let usernameField = controller.textFields?[0]
            let username = usernameField?.text ?? ""
            if username.count < 3 || username.count > 16 {
                controller.message = localize("login.error.username.outOfRange")
                self.present(controller, animated: true)
            } else {
                let authenticator = LocalAuthenticator(input: username)
                callAuthenticator(authenticator, "loginWithCallback:") { [weak self] _, _ in
                    // The Obj-C code ran this on whatever thread the authenticator called back on
                    self?.whenItemSelected?()
                    self?.dismiss(animated: true)
                }
            }
        })
        controller.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
        present(controller, animated: true)
    }

    func actionLoginMicrosoft(_ sender: UITableViewCell) {
        guard let url = URL(string: "https://login.live.com/oauth20_authorize.srf?client_id=00000000402b5328&response_type=code&scope=service%3A%3Auser.auth.xboxlive.com%3A%3AMBI_SSL&redirect_url=https%3A%2F%2Flogin.live.com%2Foauth20_desktop.srf") else { return }

        authVC = ASWebAuthenticationSession(url: url, callbackURLScheme: "ms-xal-00000000402b5328") { [weak self] callbackURL, error in
            guard let self = self else { return }
            guard let callbackURL = callbackURL else {
                if let error = error as NSError?, error.code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    showDialog(localize("Error"), error.localizedDescription)
                }
                return
            }

            let queryItems = self.parseQueryItems(callbackURL.absoluteString)
            if let code = queryItems["code"] {
                DispatchQueue.main.async {
                    self.isModalInPresentation = true
                    self.tableView.isUserInteractionEnabled = false
                    self.addActivityIndicator(to: sender)
                }
                let authenticator = MicrosoftAuthenticator(input: code)
                callAuthenticator(authenticator, "loginWithCallback:") { status, success in
                    if let text = status as? String, text == "DEMO", success {
                        showDialog(localize("login.warn.title.demomode"), localize("login.warn.message.demomode"))
                    }
                    DispatchQueue.main.async {
                        self.callbackMicrosoftAuth(status, success: success, for: sender)
                    }
                }
            } else {
                if (queryItems["error"] ?? "").hasPrefix("access_denied") {
                    // Ignore access denial responses
                    return
                }
                showDialog(localize("Error"), queryItems["error_description"] ?? "")
            }
        }

        authVC?.prefersEphemeralWebBrowserSession = true
        authVC?.presentationContextProvider = self

        if authVC?.start() == false {
            showDialog(localize("Error"), "Unable to open Safari")
        }
    }

    func addActivityIndicator(to cell: UITableViewCell) {
        let indicator = UIActivityIndicatorView(style: .medium)
        cell.accessoryView = indicator
        indicator.sizeToFit()
        indicator.startAnimating()
    }

    func removeActivityIndicator(from cell: UITableViewCell) {
        (cell.accessoryView as? UIActivityIndicatorView)?.stopAnimating()
        cell.accessoryView = nil
    }

    func callbackMicrosoftAuth(_ status: Any?, success: Bool, for cell: UITableViewCell) {
        if let status = status {
            if success {
                cell.detailTextLabel?.text = status as? String
            } else {
                isModalInPresentation = false
                tableView.isUserInteractionEnabled = true
                removeActivityIndicator(from: cell)
                let error = status as? NSError
                cell.detailTextLabel?.text = error?.localizedDescription
                // AFNetworkingOperationFailingURLResponseDataErrorKey
                let errorData = error?.userInfo["com.alamofire.serialization.response.error.data"] as? Data
                let errorStr = errorData.flatMap { String(data: $0, encoding: .utf8) }
                NSLog("[MSA] Error: %@", errorStr ?? "(null)")
                showDialog(localize("Error"), errorStr ?? "")
            }
        } else if success {
            whenItemSelected?()
            removeActivityIndicator(from: cell)
            dismiss(animated: true)
        }
    }

    // MARK: UIPopoverPresentationControllerDelegate

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
