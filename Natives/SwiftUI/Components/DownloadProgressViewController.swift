import UIKit
import ObjectiveC


private let cellProgressContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
private let totalProgressContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

private var cellAssociationKey: UInt8 = 0       // NSProgress -> UITableViewCell showing it
private var progressAssociationKey: UInt8 = 0   // UITableViewCell -> NSProgress it shows


private final class WeakProgress {
    weak var progress: Progress?
    init(_ progress: Progress) { self.progress = progress }
}

private extension UIControl {
    func wfSetFractionCompleted(_ value: Double) { setValue(NSNumber(value: value), forKey: "fractionCompleted") }

    func wfReset() { _ = perform(NSSelectorFromString("reset")) }

    func wfTransitionCompleted(visible: Bool, animated: Bool, haptic: Bool) {
        let selector = NSSelectorFromString("transitionCompletedLayerToVisible:animated:haptic:")
        guard responds(to: selector), let imp = method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Bool, Bool, Bool) -> Void
        unsafeBitCast(imp, to: Function.self)(self, selector, visible, animated, haptic)
    }

    func wfTransitionRunning(visible: Bool, animated: Bool) {
        let selector = NSSelectorFromString("transitionRunningLayerToVisible:animated:")
        guard responds(to: selector), let imp = method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        unsafeBitCast(imp, to: Function.self)(self, selector, visible, animated)
    }
}

/// Shows the progress of every file of a running download.
@objc(DownloadProgressViewController)
@objcMembers
class DownloadProgressViewController: UITableViewController {
    var task: MinecraftResourceDownloadTask!

    private var fileListCount = 0
    private var cellObservations: [(progress: Progress, count: Int)] = []
    private var observingTotal = false

    init(task: MinecraftResourceDownloadTask) {
        self.task = task
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        for observation in cellObservations {
            for _ in 0..<observation.count {
                observation.progress.removeObserver(self, forKeyPath: "fractionCompleted")
            }
        }
    }

    override func loadView() {
        super.loadView()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(actionClose))
        tableView.allowsSelection = false

        // Load WFWorkflowProgressView
        _ = dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !observingTotal {
            task.textProgress.addObserver(self, forKeyPath: "fractionCompleted", options: .initial, context: totalProgressContext)
            observingTotal = true
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if observingTotal {
            task.textProgress.removeObserver(self, forKeyPath: "fractionCompleted")
            observingTotal = false
        }
    }

    func actionClose() {
        navigationController?.dismiss(animated: true)
    }

    private func addCellObserver(_ progress: Progress) {
        if let index = cellObservations.firstIndex(where: { $0.progress === progress }) {
            cellObservations[index].count += 1
        } else {
            cellObservations.append((progress, 1))
        }
        progress.addObserver(self, forKeyPath: "fractionCompleted", options: .initial, context: cellProgressContext)
    }

    private func removeCellObserver(_ progress: Progress) {
        guard let index = cellObservations.firstIndex(where: { $0.progress === progress }) else { return }
        progress.removeObserver(self, forKeyPath: "fractionCompleted")
        cellObservations[index].count -= 1
        if cellObservations[index].count == 0 {
            cellObservations.remove(at: index)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context == cellProgressContext {
            guard let progress = object as? Progress,
                  let cell = objc_getAssociatedObject(progress, &cellAssociationKey) as? UITableViewCell else { return }
            DispatchQueue.main.async {
                cell.detailTextLabel?.text = progress.localizedAdditionalDescription
                if let progressView = cell.accessoryView as? UIControl {
                    progressView.wfSetFractionCompleted(progress.fractionCompleted)
                    if progress.isFinished {
                        progressView.wfTransitionCompleted(visible: true, animated: false, haptic: false)
                    }
                }
            }
        } else if context == totalProgressContext {
            guard let progress = object as? Progress else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.title = progress.localizedDescription
                let count = self.task.fileList?.count ?? 0
                if self.fileListCount != count {
                    self.tableView.reloadData()
                }
                self.fileListCount = count
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return task.fileList?.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        if let reused = tableView.dequeueReusableCell(withIdentifier: "cell") {
            cell = reused
        } else {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
            if let viewClass = NSClassFromString("WFWorkflowProgressView") as? UIControl.Type {
                let progressView = viewClass.init(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
                progressView.setValue(view.tintColor, forKey: "resolvedTintColor")
                progressView.setValue(NSNumber(value: 0), forKey: "stopSize")
                cell.accessoryView = progressView
            }
        }

        // Unset the last cell displaying the progress
        let lastProgress = (objc_getAssociatedObject(cell, &progressAssociationKey) as? WeakProgress)?.progress
        if let lastProgress = lastProgress {
            objc_setAssociatedObject(lastProgress, &cellAssociationKey, nil, .OBJC_ASSOCIATION_ASSIGN)
            removeCellObserver(lastProgress)
        }

        guard let progressList = task.progressList, indexPath.row < progressList.count,
              let progress = progressList[indexPath.row] as? Progress else {
            return cell
        }
        objc_setAssociatedObject(cell, &progressAssociationKey, WeakProgress(progress), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(progress, &cellAssociationKey, cell, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addCellObserver(progress)

        if let progressView = cell.accessoryView as? UIControl {
            if lastProgress?.isFinished == true {
                progressView.wfReset()
            }
            progressView.wfSetFractionCompleted(progress.fractionCompleted)
            progressView.wfTransitionCompleted(visible: progress.isFinished, animated: false, haptic: false)
            progressView.wfTransitionRunning(visible: !progress.isFinished, animated: false)
        }

        cell.textLabel?.text = task.fileList?[indexPath.row] as? String
        cell.detailTextLabel?.text = progress.localizedAdditionalDescription
        return cell
    }
}
