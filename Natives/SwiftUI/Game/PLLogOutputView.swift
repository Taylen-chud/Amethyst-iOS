import UIKit

@objc(PLLogOutputView)
class PLLogOutputView: UIView, UITableViewDataSource, UITableViewDelegate {
    var navController: UINavigationController?
    private var logTableView: UITableView!
    private var navigationBar: UINavigationBar!

    private static var fatalErrorOccurred = false
    private static var logLines: [String] = []
    private static var current: PLLogOutputView?

    override init(frame originalFrame: CGRect) {
        var frame = originalFrame
        let vc = UIViewController()
        let nav = UINavigationController(rootViewController: vc)
        navController = nav
        navigationBar = nav.navigationBar

        frame.origin.y = frame.size.height
        super.init(frame: frame)
        vc.view = self
        frame.origin.y = 0

        PLLogOutputView.logLines = []
        backgroundColor = UIColor(white: 0, alpha: 0.5)
        nav.view.isHidden = true

        vc.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .stop, target: self, action: #selector(actionToggleLogOutput)),
            UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(actionClearLogOutput))
        ]
        vc.title = localize("game.menu.log_output")

        logTableView = UITableView(frame: frame)
        //logTableView.allowsSelection = false
        logTableView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        logTableView.backgroundColor = UIColor.clear
        logTableView.contentInset = UIEdgeInsets(top: navigationBar.frame.size.height, left: 0, bottom: 0, right: 0)
        logTableView.dataSource = self
        logTableView.delegate = self
        logTableView.layoutMargins = .zero
        logTableView.rowHeight = 20
        logTableView.separatorInset = .zero
        logTableView.separatorStyle = .none
        addSubview(logTableView)
        addSubview(navigationBar)

        canAppendToLog = true
        actionStartStopLogOutput()

        PLLogOutputView.current = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return PLLogOutputView.logLines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var cell = tableView.dequeueReusableCell(withIdentifier: "cell")

        if cell == nil {
            let created = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
            created.backgroundColor = UIColor.clear
            //created.selectionStyle = .none
            created.textLabel?.font = UIFont(name: "Menlo-Regular", size: 16)
            created.textLabel?.textColor = UIColor.white
            cell = created
        }
        cell?.textLabel?.text = PLLogOutputView.logLines[indexPath.row]

        return cell!
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)

        let cell = tableView.cellForRow(at: indexPath)
        guard let line = cell?.textLabel?.text else { return }
        if line.count == 0 || line == "\n" {
            return
        }

        let alert = UIAlertController(title: nil, message: line, preferredStyle: .actionSheet)
        alert.popoverPresentationController?.sourceView = cell
        alert.popoverPresentationController?.sourceRect = cell?.bounds ?? .zero
        // The original wrapped the key in localize twice: localize(localize(@"Share"))
        let share = UIAlertAction(title: localize(localize("Share")), style: .default) { [weak self] _ in
            let activityVC = UIActivityViewController(activityItems: [line], applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = self?.navigationBar
            activityVC.popoverPresentationController?.sourceRect = self?.navigationBar.bounds ?? .zero
            currentVC()?.present(activityVC, animated: true, completion: nil)
        }
        let cancel = UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil)
        alert.addAction(share)
        alert.addAction(cancel)
        currentVC()?.present(alert, animated: true, completion: nil)
    }

    @objc func actionClearLogOutput() {
        PLLogOutputView.logLines.removeAll()
        logTableView.reloadData()
    }

    @objc func actionShareLatestlog() {
        let latestlogPath = "file://\(envString("AME_HOME") ?? "(null)")/latestlog.txt"
        var items: [Any] = ["latestlog.txt"]
        if let url = URL(string: latestlogPath) { items.append(url) }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = navigationBar
        activityVC.popoverPresentationController?.sourceRect = navigationBar.bounds
        currentVC()?.present(activityVC, animated: true, completion: nil)
    }

    @objc func actionStartStopLogOutput() {
        canAppendToLog = !canAppendToLog
        let item = navigationBar.items![0]
        item.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: canAppendToLog ? .pause : .play,
                                                 target: self, action: #selector(actionStartStopLogOutput))
    }

    @objc func actionToggleLogOutput() {
        if PLLogOutputView.fatalErrorOccurred {
            // [UIApplication.sharedApplication performSelector:@selector(suspend)]
            _ = UIApplication.shared.perform(NSSelectorFromString("suspend"))
            fatalExitGroup.leave()
            return
        }

        guard let navView = navController?.view else { return }
        UIView.transition(with: self, duration: 0.4, options: .curveEaseOut, animations: {
            var frame = self.frame
            frame.origin.y = navView.isHidden ? 0 : frame.size.height
            navView.isHidden = false
            self.frame = frame
        }, completion: { _ in
            navView.isHidden = self.frame.origin.y != 0
        })
    }

    private class func _appendToLog(_ line: String) {
        if line.count == 0 {
            return
        }

        let indexPath = IndexPath(row: logLines.count, section: 0)
        logLines.append(line)
        UIView.setAnimationsEnabled(false)
        current?.logTableView.beginUpdates()
        current?.logTableView.insertRows(at: [indexPath], with: .none)
        current?.logTableView.endUpdates()
        UIView.setAnimationsEnabled(true)

        current?.logTableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
    }

    @objc(appendToLog:)
    class func appendToLog(_ string: String) {
        DispatchQueue.main.async {
            let lines = string.components(separatedBy: .newlines)
            for line in lines {
                _appendToLog(line)
            }
        }
    }

    @objc(handleExitCode:)
    class func handleExitCode(_ code: Int32) -> Bool {
        guard current != nil else { return false }
        DispatchQueue.main.async {
            guard let current = current else { return }
            if current.navController?.view.isHidden == true {
                current.actionToggleLogOutput()
            }
            // Cleanup navigation bar
            let navigationBar: UINavigationBar = current.navigationBar
            navigationBar.topItem?.title = String(format: localize("game.title.exit_code"), code)
            navigationBar.items![0].leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action,
                                                                         target: current, action: #selector(PLLogOutputView.actionShareLatestlog))
            let exitItem = navigationBar.items![0].rightBarButtonItems![0]
            navigationBar.items![0].rightBarButtonItems = nil
            navigationBar.items![0].rightBarButtonItem = exitItem

            if canAppendToLog {
                canAppendToLog = false
                fatalErrorOccurred = true
                return
            }
            current.actionClearLogOutput()
            _appendToLog("... (latestlog.txt)")
            let latestlogPath = "\(envString("AME_HOME") ?? "(null)")/latestlog.txt"
            let linesStr = (try? String(contentsOfFile: latestlogPath, encoding: .utf8)) ?? ""
            let lines = linesStr.components(separatedBy: .newlines)

            // Print last 100 lines from latestlog.txt
            var i = (lines.count > 100) ? lines.count - 100 : 0
            while i < lines.count {
                _appendToLog(lines[i])
                i += 1
            }

            fatalErrorOccurred = true
        }
        return true
    }
}
