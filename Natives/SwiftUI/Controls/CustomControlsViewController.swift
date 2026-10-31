import UIKit

extension ControlButton {
    /// `button.properties[key]`
    func prop(_ key: String) -> Any? {
        return properties?.object(forKey: key)
    }

    /// `button.properties[key] = value`
    func setProp(_ key: String, _ value: Any?) {
        guard let properties = properties else { return }
        if let value = value {
            properties.setObject(value, forKey: key as NSString)
        } else {
            properties.removeObject(forKey: key)
        }
    }
}

/// `[button snapAndAlignX:x Y:y]`, called by selector so the Swift import name does not matter
func controlSnapAndAlign(_ button: ControlButton, x: CGFloat, y: CGFloat) {
    let sel = NSSelectorFromString("snapAndAlignX:Y:")
    guard button.responds(to: sel), let imp = button.method(for: sel) else {
        NSLog("[CustomControls] ControlButton does not respond to snapAndAlignX:Y:")
        return
    }
    typealias Function = @convention(c) (AnyObject, Selector, CGFloat, CGFloat) -> Void
    unsafeBitCast(imp, to: Function.self)(button, sel, x, y)
}

/// `[cls buttonWithProperties:dict]` / `[cls buttonWithData:dict]`
func controlMake(_ cls: AnyClass, selector: String, _ dict: NSMutableDictionary) -> ControlButton? {
    return objcSend(cls, selector, dict) as? ControlButton
}

// MARK: - ControlHandleView

@objc(ControlHandleView)
class ControlHandleView: UIView {
    weak var target: ControlButton?
}

// MARK: - CustomControlsViewController

@objc(CustomControlsViewController)
class CustomControlsViewController: UIViewController, UIGestureRecognizerDelegate, UIPopoverPresentationControllerDelegate {
    var getDefaultCtrl: (() -> String)?
    var setDefaultCtrl: ((String) -> Void)?

    var currentGesture: UIGestureRecognizer?

    var ctrlView: ControlLayout!
    var resizeView: ControlHandleView!

    private var currentFileName: String?
    private var selectedPoint: CGRect = .zero
    private var navigationBar: UINavigationBar!

    // Were `static` locals in the Obj-C gesture handlers
    private var panPrevious: CGPoint = .zero
    private var pinchPrevious: CGPoint = .zero
    private var origButtonRect: CGRect = .zero
    private var origHandleButtonRect: CGRect = .zero

    private var isInGame: Bool {
        return presentingViewController is SurfaceViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        undoManager?.removeAllActions()
        view.backgroundColor = UIColor(white: 0.2, alpha: 0.5)
        isControlModifiable = true

        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()

        let insets = UIApplication.shared.windows.first?.safeAreaInsets ?? .zero

        let guideLabel = UILabel(frame: view.frame)
        guideLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        guideLabel.numberOfLines = 0
        guideLabel.textAlignment = .center
        guideLabel.textColor = .white
        guideLabel.text = localize("custom_controls.hint")
        view.addSubview(guideLabel)

        ctrlView = ControlLayout(frame: getSafeArea(view.frame))
        ctrlView.layer.borderColor = UIColor.label.cgColor
        view.addSubview(ctrlView)

        // Prepare the navigation bar for safe area customization
        let navigationItem = UINavigationItem()
        let segmentedControl = UISegmentedControl(items: ["None", "Default", "Custom"])
        segmentedControl.addTarget(self, action: #selector(changeSafeAreaSelection(_:)), for: .valueChanged)
        segmentedControl.setEnabled((insets.left + insets.right) > 0, forSegmentAt: 1)
        loadSafeAreaSelection(for: segmentedControl)
        navigationItem.titleView = segmentedControl
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(actionMenuSafeAreaCancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(actionMenuSafeAreaDone))
        navigationBar = UINavigationBar(frame: CGRect(x: 0, y: 0, width: view.frame.size.width, height: 44.0))
        navigationBar.autoresizingMask = .flexibleWidth
        navigationBar.isHidden = true
        navigationBar.items = [navigationItem]
        navigationBar.isTranslucent = true
        view.addSubview(navigationBar)

        resizeView = ControlHandleView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        resizeView.backgroundColor = view.tintColor
        resizeView.layer.cornerRadius = resizeView.frame.size.width / 2
        resizeView.clipsToBounds = true
        resizeView.isHidden = true
        resizeView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(onTouch(_:))))
        view.addSubview(resizeView)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(panControlArea(_:)))
        panGesture.delegate = self
        panGesture.maximumNumberOfTouches = 1
        ctrlView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(pinchControlArea(_:)))
        pinchGesture.delegate = self
        ctrlView.addGestureRecognizer(pinchGesture)

        let longpressGesture = UILongPressGestureRecognizer(target: self, action: #selector(showControlPopover(_:)))
        longpressGesture.minimumPressDuration = 0.5
        ctrlView.addGestureRecognizer(longpressGesture)

        let fileName = getDefaultCtrl?() ?? ""
        currentFileName = (fileName as NSString).deletingPathExtension
        loadControlFile(fileName)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isControlModifiable = false
        if let game = presentingViewController as? SurfaceViewController {
            game.loadCustomControls()
        }
    }

    func gestureRecognizer(_ sender: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return sender.view != view || !resizeView.frame.contains(sender.location(in: view))
    }

    @objc func panControlArea(_ sender: UIPanGestureRecognizer) {
        if sender.state == .began {
            setButtonMenuVisible(for: nil)
            resizeView.isHidden = ctrlView.layer.borderWidth == 0
            resizeView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
            panPrevious = sender.location(in: view)
            return
        } else if navigationBar.isHidden {
            return
        }

        let current = sender.location(in: view)

        var rect = ctrlView.frame
        rect.origin.x = clamp(rect.origin.x + current.x - panPrevious.x, 0, view.frame.size.width - rect.size.width)
        rect.origin.y = clamp(rect.origin.y + current.y - panPrevious.y, 0, view.frame.size.height - rect.size.height)
        ctrlView.frame = rect

        resizeView.frame = CGRect(x: ctrlView.frame.maxX - resizeView.frame.size.width,
                                  y: ctrlView.frame.maxY - resizeView.frame.size.height,
                                  width: resizeView.frame.size.width, height: resizeView.frame.size.height)

        panPrevious = current
    }

    @objc func pinchControlArea(_ sender: UIPinchGestureRecognizer) {
        if sender.numberOfTouches < 2 || navigationBar.isHidden {
            return
        }

        let current = sender.location(in: view)
        if sender.state == .began {
            pinchPrevious = current
            return
        }

        ctrlView.frame = CGRect(
            x: clamp(ctrlView.frame.origin.x + current.x - pinchPrevious.x, 0, view.frame.size.width - ctrlView.frame.size.width),
            y: clamp(ctrlView.frame.origin.y + current.y - pinchPrevious.y, 0, view.frame.size.height - ctrlView.frame.size.height),
            width: clamp(ctrlView.frame.size.width * sender.scale, view.frame.size.width / 2, view.frame.size.width),
            height: clamp(ctrlView.frame.size.height * sender.scale, view.frame.size.height / 2, view.frame.size.height)
        )
        resizeView.frame = CGRect(x: ctrlView.frame.maxX, y: ctrlView.frame.maxY,
                                  width: resizeView.frame.size.width, height: resizeView.frame.size.height)

        pinchPrevious = current

        sender.scale = 1.0
    }

    func loadControlFile(_ file: String) {
        ctrlView.loadControlFile(file)
        for case let button as ControlButton in ctrlView.subviews {
            button.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showControlPopover(_:))))
            button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(onTouch(_:))))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if navigationBar.isHidden {
            ctrlView.frame = getSafeArea(view.frame)
        }

        // Update dynamic position for each view
        for case let button as ControlButton in ctrlView.subviews {
            button.update()
        }
    }

    @objc func changeSafeAreaSelection(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 0:
            ctrlView.frame = view.frame
        case 1:
            ctrlView.frame = view.frame.inset(by: getDefaultSafeArea())
        case 2:
            ctrlView.frame = getSafeArea(view.frame)
        default:
            break
        }
        ctrlView.isUserInteractionEnabled = sender.selectedSegmentIndex == 2
        resizeView.isHidden = sender.selectedSegmentIndex != 2
    }

    private func loadSafeAreaSelection(for control: UISegmentedControl) {
        if ctrlView.frame.equalTo(UIScreen.main.bounds) {
            control.selectedSegmentIndex = 0
        } else {
            let isDefault = ctrlView.frame.equalTo(view.frame.inset(by: getDefaultSafeArea()))
            control.selectedSegmentIndex = (isDefault ? 0 : 1) + 1
        }
    }

    @objc func showControlPopover(_ sender: UIGestureRecognizer) {
        currentGesture = sender

        if sender.state != .began && sender.state != .ended {
            return
        }

        let menuController = UIMenuController.shared

        if !(sender.view is ControlButton) {
            let actionExit = UIMenuItem(title: localize("custom_controls.control_menu.exit"), action: #selector(actionMenuExit))
            let actionSave = UIMenuItem(title: localize("custom_controls.control_menu.save"), action: #selector(actionMenuSave))
            let actionLoad = UIMenuItem(title: localize("custom_controls.control_menu.load"), action: #selector(actionMenuLoad))
            let actionSafeArea = UIMenuItem(title: localize("custom_controls.control_menu.safe_area"), action: #selector(actionMenuSafeArea))
            let actionAddButton = UIMenuItem(title: localize("custom_controls.control_menu.add_button"), action: #selector(actionMenuAddButton))
            let actionAddDrawer = UIMenuItem(title: localize("custom_controls.control_menu.add_drawer"), action: #selector(actionMenuAddDrawer))
            let actionAddJoystick = UIMenuItem(title: localize("custom_controls.control_menu.add_joystick"), action: #selector(actionMenuAddJoystick))
            menuController.menuItems = [actionExit, actionSave, actionLoad, actionSafeArea, actionAddButton, actionAddDrawer, actionAddJoystick]

            let point = sender.location(in: sender.view)
            selectedPoint = CGRect(x: point.x, y: point.y, width: 1.0, height: 1.0)
        } else {
            let actionEdit = UIMenuItem(title: localize("Edit"), action: #selector(actionMenuBtnEdit))
            let actionDelete = UIMenuItem(title: localize("Remove"), action: #selector(actionMenuBtnDelete))
            if sender.view is ControlDrawer {
                let actionAddSubButton = UIMenuItem(title: localize("custom_controls.button_menu.add_subbutton"), action: #selector(actionMenuAddSubButton))
                menuController.menuItems = [actionEdit, /* actionCopy, */ actionDelete, actionAddSubButton]
            } else {
                menuController.menuItems = [actionEdit, /* actionCopy, */ actionDelete]
            }
            selectedPoint = sender.view?.bounds ?? .zero
        }

        if sender.view != ctrlView {
            ctrlView.becomeFirstResponder()
        }
        sender.view?.becomeFirstResponder()

        resizeView.isHidden = sender.view == ctrlView
        setButtonMenuVisible(for: sender.view)
    }

    @objc func actionMenuExit() {
        if undoManager?.canUndo == true {
            presentSaveDialog(exit: true)
            return
        }
        dismiss(animated: !isInGame, completion: nil)
    }

    private func presentSaveDialog(exit: Bool) {
        let controller = UIAlertController(
            title: localize("custom_controls.control_menu.save"),
            message: exit ? localize("custom_controls.control_menu.exit.warn") : "",
            preferredStyle: .alert)
        controller.addTextField { [weak self] textField in
            textField.placeholder = "Name"
            textField.text = self?.currentFileName
            textField.clearButtonMode = .whileEditing
            textField.borderStyle = .roundedRect
        }
        controller.addAction(UIAlertAction(title: localize("OK"), style: .default) { [weak self, weak controller] _ in
            guard let self = self, let field = controller?.textFields?.first else { return }
            let jsonData: Data
            do {
                jsonData = try JSONSerialization.data(withJSONObject: self.ctrlView.layoutDictionary as Any, options: .prettyPrinted)
            } catch {
                showDialog(localize("custom_controls.control_menu.save.error.json"), error.localizedDescription)
                return
            }
            let path = "\(envString("AME_HOME") ?? "")/controlmap/\(field.text ?? "").json"
            do {
                try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                showDialog(localize("custom_controls.control_menu.save.error.write"), error.localizedDescription)
                return
            }

            if exit {
                self.dismiss(animated: !self.isInGame, completion: nil)
            }

            self.currentFileName = field.text
            self.undoManager?.removeAllActions()
        })
        if exit {
            controller.addAction(UIAlertAction(title: localize("custom_controls.control_menu.discard_changes"), style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.dismiss(animated: !self.isInGame, completion: nil)
            })
        }
        controller.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
        present(controller, animated: true, completion: nil)
    }

    @objc func actionMenuSave() {
        presentSaveDialog(exit: false)
    }

    private func actionOpenFilePicker(_ handler: @escaping (String) -> Void) {
        let vc = FileListViewController()
        vc.listPath = "\(envString("AME_HOME") ?? "")/controlmap"
        vc.whenItemSelected = handler
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = CGSize(width: 350, height: 250)

        if let popoverController = vc.popoverPresentationController {
            popoverController.sourceView = view
            popoverController.sourceRect = selectedPoint
            popoverController.permittedArrowDirections = .any
            popoverController.delegate = self
        }
        present(vc, animated: true, completion: nil)
    }

    @objc func actionMenuLoad() {
        actionOpenFilePicker { [weak self] name in
            guard let self = self else { return }
            self.currentFileName = name
            let fileName = "\(name).json"
            self.loadControlFile(fileName)
            self.setDefaultCtrl?(fileName)
        }
    }

    @objc func actionMenuSafeArea() {
        // Set _UIBarBackground alpha to 0.8
        navigationBar.subviews.first?.alpha = 0.8

        let isCustom = (navigationBar.items?.first?.titleView as? UISegmentedControl)?.selectedSegmentIndex == 2

        navigationBar.isHidden = !navigationBar.isHidden
        ctrlView.layer.borderWidth = navigationBar.isHidden ? 0 : 2
        ctrlView.isUserInteractionEnabled = navigationBar.isHidden || isCustom
        resizeView.frame = CGRect(x: ctrlView.frame.maxX, y: ctrlView.frame.maxY,
                                  width: resizeView.frame.size.width, height: resizeView.frame.size.height)
        resizeView.isHidden = navigationBar.isHidden || !isCustom
        resizeView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
        resizeView.target = nil
    }

    @objc func actionMenuSafeAreaCancel() {
        ctrlView.frame = getSafeArea(view.frame)
        actionMenuSafeArea()
    }

    @objc func actionMenuSafeAreaDone() {
        setSafeArea(view.frame.size, ctrlView.frame)
        actionMenuSafeArea()
    }

    private func controlList(_ key: String) -> NSArray? {
        return ctrlView.layoutDictionary?.object(forKey: key) as? NSArray
    }

    private func attachEditGestures(to button: UIView) {
        button.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showControlPopover(_:))))
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(onTouch(_:))))
    }

    private func addButton(withDrawer drawer: ControlDrawer?) {
        let dict = NSMutableDictionary()
        dict.setObject("New", forKey: "name" as NSString)
        dict.setObject(NSMutableArray(array: [NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 0)]),
                       forKey: "keycodes" as NSString)
        dict.setObject("0", forKey: "dynamicX" as NSString)
        dict.setObject("0", forKey: "dynamicY" as NSString)
        dict.setObject(NSNumber(value: 50.0), forKey: "width" as NSString)
        dict.setObject(NSNumber(value: 50.0), forKey: "height" as NSString)
        dict.setObject(NSNumber(value: 1), forKey: "opacity" as NSString)
        dict.setObject(NSNumber(value: 0), forKey: "cornerRadius" as NSString)
        dict.setObject(NSNumber(value: 0x4d000000), forKey: "bgColor" as NSString)

        let button: ControlButton
        if let drawer = drawer {
            guard let sub = controlMake(ControlSubButton.self, selector: "buttonWithProperties:", dict) else { return }
            (sub as? ControlSubButton)?.parentDrawer = drawer
            button = sub
            doAddButton(button, atIndex: drawer.buttons?.count ?? 0)
            controlSnapAndAlign(button, x: selectedPoint.origin.x - 25.0, y: selectedPoint.origin.y - 25.0)
            button.update()
            drawer.syncButtons()
        } else {
            dict.setObject(NSNumber(value: true), forKey: "displayInGame" as NSString)
            dict.setObject(NSNumber(value: true), forKey: "displayInMenu" as NSString)
            guard let plain = controlMake(ControlButton.self, selector: "buttonWithProperties:", dict) else { return }
            button = plain
            doAddButton(button, atIndex: controlList("mControlDataList")?.count ?? 0)
            controlSnapAndAlign(button, x: selectedPoint.origin.x - 25.0, y: selectedPoint.origin.y - 25.0)
            button.update()
        }

        attachEditGestures(to: button)
    }

    @objc func actionMenuAddButton() {
        addButton(withDrawer: nil)
    }

    @objc func actionMenuAddDrawer() {
        let properties = NSMutableDictionary()
        properties.setObject("New", forKey: "name" as NSString)
        properties.setObject("0", forKey: "dynamicX" as NSString)
        properties.setObject("0", forKey: "dynamicY" as NSString)
        properties.setObject(NSNumber(value: 50.0), forKey: "width" as NSString)
        properties.setObject(NSNumber(value: 50.0), forKey: "height" as NSString)
        properties.setObject(NSNumber(value: 1), forKey: "opacity" as NSString)
        properties.setObject(NSNumber(value: 0), forKey: "cornerRadius" as NSString)
        properties.setObject(NSNumber(value: 0x4d000000), forKey: "bgColor" as NSString)
        properties.setObject(NSNumber(value: true), forKey: "displayInGame" as NSString)
        properties.setObject(NSNumber(value: true), forKey: "displayInMenu" as NSString)
        let data = NSMutableDictionary()
        data.setObject("FREE", forKey: "orientation" as NSString)
        data.setObject(properties, forKey: "properties" as NSString)
        data.setObject(NSMutableArray(), forKey: "buttonProperties" as NSString)
        guard let button = controlMake(ControlDrawer.self, selector: "buttonWithData:", data) else { return }
        doAddButton(button, atIndex: controlList("mDrawerDataList")?.count ?? 0)
        controlSnapAndAlign(button, x: selectedPoint.origin.x - 25.0, y: selectedPoint.origin.y - 25.0)
        button.update()

        attachEditGestures(to: button)
    }

    @objc func actionMenuAddSubButton() {
        guard let drawerView = currentGesture?.view as? ControlDrawer else { return }
        selectedPoint = CGRect(x: drawerView.frame.origin.x + 25.0, y: drawerView.frame.origin.y + 25.0, width: 1.0, height: 1.0)
        addButton(withDrawer: drawerView)
    }

    @objc func actionMenuAddJoystick() {
        let dict = NSMutableDictionary()
        dict.setObject("0", forKey: "dynamicX" as NSString)
        dict.setObject("0", forKey: "dynamicY" as NSString)
        dict.setObject(NSNumber(value: 100.0), forKey: "width" as NSString)
        dict.setObject(NSNumber(value: 100.0), forKey: "height" as NSString)
        dict.setObject(NSNumber(value: 1), forKey: "opacity" as NSString)
        dict.setObject(NSNumber(value: 0x4d000000), forKey: "bgColor" as NSString)
        dict.setObject(NSNumber(value: 0xffffffff as UInt32), forKey: "strokeColor" as NSString)
        dict.setObject(NSNumber(value: true), forKey: "displayInGame" as NSString)
        dict.setObject(NSNumber(value: true), forKey: "displayInMenu" as NSString)
        dict.setObject(NSNumber(value: false), forKey: "forwardLock" as NSString)
        guard let button = controlMake(ControlJoystick.self, selector: "buttonWithProperties:", dict) else { return }
        doAddButton(button, atIndex: controlList("mJoystickDataList")?.count ?? 0)
        controlSnapAndAlign(button, x: selectedPoint.origin.x - 25.0, y: selectedPoint.origin.y - 25.0)
        button.update()
        attachEditGestures(to: button)
    }

    @objc func actionMenuBtnCopy() {
        // copy
    }

    @objc func actionMenuBtnDelete() {
        resizeView.isHidden = true
        guard let button = currentGesture?.view as? ControlButton else { return }
        doRemoveButton(button)
    }

    @objc func actionMenuBtnEdit() {
        let vc = CCMenuViewController()
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        vc.preferredContentSize = view.frame.size
        if !(currentGesture is UILongPressGestureRecognizer) {
            vc.targetButton = currentGesture?.view as? ControlButton
        }
        present(vc, animated: true, completion: nil)
    }

    private func setButtonMenuVisible(for targetView: UIView?) {
        resizeView.layer.maskedCorners = [.layerMaxXMaxYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
        resizeView.target = targetView as? ControlButton
        let menuController = UIMenuController.shared
        if let targetView = targetView {
            menuController.showMenu(from: targetView, rect: selectedPoint)
        } else {
            menuController.hideMenu()
        }

        if let targetView = targetView {
            let origin = ctrlView.convert(targetView.frame.origin, to: view)
            resizeView.frame = CGRect(x: origin.x + targetView.frame.size.width, y: origin.y + targetView.frame.size.height,
                                      width: resizeView.frame.size.width, height: resizeView.frame.size.height)
        }
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return .all
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return getPrefBool("debug.debug_hide_home_indicator")
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    private func onTouchAreaHandleView(_ sender: UIPanGestureRecognizer) {
        if sender.state != .changed { return }
        let translation = sender.translation(in: sender.view)

        // Perform safe area resize
        var targetFrame = ctrlView.frame
        targetFrame.size.width += translation.x
        targetFrame.size.height += translation.y
        ctrlView.frame = targetFrame

        // Keep track of handle view location
        targetFrame = resizeView.frame
        targetFrame.origin.x = ctrlView.frame.maxX - targetFrame.size.width
        targetFrame.origin.y = ctrlView.frame.maxY - targetFrame.size.height
        resizeView.frame = targetFrame

        sender.setTranslation(.zero, in: sender.view)
    }

    private func onTouchButtonHandleView(_ sender: UIPanGestureRecognizer) {
        guard let target = resizeView.target else { return }
        let translation = sender.translation(in: sender.view)

        switch sender.state {
        case .began:
            // Save old button frame
            origHandleButtonRect = target.frame
        case .changed:
            // Perform button resize
            let width = max(10, CGFloat((target.prop("width") as? NSNumber)?.floatValue ?? 0) + translation.x)
            let height = max(10, CGFloat((target.prop("height") as? NSNumber)?.floatValue ?? 0) + translation.y)
            target.setProp("width", NSNumber(value: Double(width)))
            target.setProp("height", NSNumber(value: Double(height)))
            target.update()
            sender.setTranslation(.zero, in: sender.view)

            // Keep track of handle view location
            resizeView.frame = CGRect(x: target.frame.maxX, y: target.frame.maxY,
                                      width: resizeView.frame.size.width, height: resizeView.frame.size.height)
        case .cancelled, .ended:
            doMoveOrResizeButton(target, from: origHandleButtonRect, to: target.frame)
        default:
            break
        }
    }

    @objc func onTouch(_ sender: UIPanGestureRecognizer) {
        if sender.view is ControlHandleView {
            if resizeView.target == nil {
                onTouchAreaHandleView(sender)
            } else {
                onTouchButtonHandleView(sender)
            }
            return
        }

        let translation = sender.translation(in: sender.view)

        guard let button = sender.view as? ControlButton else { return }
        if let sub = button as? ControlSubButton,
           (sub.parentDrawer?.drawerData?.object(forKey: "orientation") as? String) != "FREE" {
            return
        }

        switch sender.state {
        case .began:
            origButtonRect = button.frame
            setButtonMenuVisible(for: nil)
            resizeView.isHidden = false
            resizeView.target = button
        case .changed:
            controlSnapAndAlign(
                button,
                x: clamp(button.frame.origin.x + translation.x, 0, ctrlView.frame.size.width - button.frame.size.width),
                y: clamp(button.frame.origin.y + translation.y, 0, ctrlView.frame.size.height - button.frame.size.height))
            sender.setTranslation(.zero, in: button)
            resizeView.frame = CGRect(x: button.frame.maxX, y: button.frame.maxY,
                                      width: resizeView.frame.size.width, height: resizeView.frame.size.height)
        case .cancelled, .ended:
            doMoveOrResizeButton(button, from: origButtonRect, to: button.frame)
        default:
            break
        }
    }

    // MARK: - UIPopoverPresentationControllerDelegate

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }
}
