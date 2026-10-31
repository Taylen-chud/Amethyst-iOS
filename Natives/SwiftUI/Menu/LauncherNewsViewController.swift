import UIKit
import WebKit

// LauncherMenuViewController builds its sidebar entries from `title` and `imageName`,
// and the Obj-C side reads `imageName` through a selector, hence @objcMembers.
@objc(LauncherNewsViewController)
@objcMembers
class LauncherNewsViewController: UIViewController, WKNavigationDelegate {

    private var webView: WKWebView!
    private var insets: UIEdgeInsets = .zero

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        title = localize("News")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func imageName() -> String { return "MenuNews" }

    override func viewDidLoad() {
        super.viewDidLoad()

        insets = UIApplication.shared.windows.first?.safeAreaInsets ?? .zero

        let request = URLRequest(url: URL(string: "https://wiki.angelauramc.dev/patchnotes/changelogs/IOS.html")!)

        let webConfig = WKWebViewConfiguration()
        webView = WKWebView(frame: view.frame, configuration: webConfig)
        webView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.isOpaque = false
        adjustWebViewForSize(view.frame.size)
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        let javascript = "var meta = document.createElement('meta');meta.setAttribute('name', 'viewport');meta.setAttribute('content', 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no');document.getElementsByTagName('head')[0].appendChild(meta);"
        let nozoom = WKUserScript(source: javascript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(nozoom)
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.load(request)
        view.addSubview(webView)

        if !isJailbroken && getPrefBool("warnings.limited_ram_warn") && (roundf(Float(ProcessInfo.processInfo.physicalMemory) / 0x1000000) < 3900) {
            // "This device has a limited amount of memory available."
            showWarningAlert(key: "limited_ram", hasPreference: true, exitWhenCompleted: false)
        }

        navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
        navigationItem.rightBarButtonItem = sidebarViewController()?.drawAccountButton()
        navigationItem.leftItemsSupplementBackButton = true
    }

    private func sidebarViewController() -> LauncherMenuViewController? {
        return (splitViewController?.viewControllers.first as? UINavigationController)?.viewControllers.first as? LauncherMenuViewController
    }

    func showWarningAlert(key: String, hasPreference: Bool, exitWhenCompleted: Bool) {
        let warning = UIAlertController(
            title: localize("login.warn.title.\(key)"),
            message: localize("login.warn.message.\(key)"),
            preferredStyle: .alert
        )

        let action: UIAlertAction
        if hasPreference {
            action = UIAlertAction(title: localize("OK"), style: .destructive) { _ in
                setPrefBool("warnings.\(key)_warn", false)
            }
        } else if exitWhenCompleted {
            action = UIAlertAction(title: localize("OK"), style: .destructive) { _ in
                // Private UIApplication -suspend, same as the Obj-C version
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
                usleep(100_000)
                exit(0)
            }
        } else {
            action = UIAlertAction(title: localize("OK"), style: .cancel)
        }

        warning.popoverPresentationController?.sourceView = view
        warning.popoverPresentationController?.sourceRect = view.bounds
        warning.addAction(action)
        present(warning, animated: true)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        adjustWebViewForSize(size)
    }

    func adjustWebViewForSize(_ size: CGSize) {
        guard let webView = webView else { return }
        let barHeight = navigationController?.navigationBar.frame.height ?? 0
        let isPortrait = size.height > size.width
        if isPortrait {
            webView.scrollView.contentInset = UIEdgeInsets(
                top: barHeight + insets.top,
                left: 0,
                bottom: barHeight + insets.bottom,
                right: 0
            )
        } else {
            webView.scrollView.contentInset = UIEdgeInsets(top: barHeight, left: 0, bottom: barHeight, right: 0)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            openLink(self, url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
