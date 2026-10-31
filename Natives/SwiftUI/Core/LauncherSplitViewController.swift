import UIKit

// ios_uikit_bridge.m looks this class up by name, so keep the unprefixed runtime name.
@objc(LauncherSplitViewController)
class LauncherSplitViewController: UISplitViewController, UISplitViewControllerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.systemBackground

        // Initialize the safe area preference if it is not set yet
        let safeArea = getPrefObject("control.control_safe_area") as? String ?? ""
        if safeArea.isEmpty {
            let i = getDefaultSafeArea()
            // Same format as NSStringFromUIEdgeInsets: {top, left, bottom, right}
            setPrefObject("control.control_safe_area", "{\(i.top), \(i.left), \(i.bottom), \(i.right)}")
        }

        delegate = self

        let masterVC = UINavigationController(rootViewController: LauncherMenuViewController())
        let detailVC = LauncherNavigationController(rootViewController: LauncherProfilesViewController())
        detailVC.isToolbarHidden = false

        viewControllers = [masterVC, detailVC]
        changeDisplayModeForSize(view.frame.size)

        maximumPrimaryColumnWidth = view.bounds.size.width * 0.95
    }

    func splitViewController(_ svc: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
        if preferredDisplayMode != displayMode && self.displayMode != .secondaryOnly {
            DispatchQueue.main.async {
                self.preferredDisplayMode = .secondaryOnly
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        changeDisplayModeForSize(size)
    }

    func changeDisplayModeForSize(_ size: CGSize) {
        let isPortrait = size.height > size.width
        if preferredDisplayMode == .automatic || displayMode != .secondaryOnly {
            if !getPrefBool("general.hidden_sidebar") {
                preferredDisplayMode = isPortrait ? .oneOverSecondary : .oneBesideSecondary
            } else {
                preferredDisplayMode = .secondaryOnly
            }
        }
        preferredSplitBehavior = isPortrait ? .overlay : .tile
    }

    @objc func dismissViewController() {
        dismiss(animated: true)
    }
}
