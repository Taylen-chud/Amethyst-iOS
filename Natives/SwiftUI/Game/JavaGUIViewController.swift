import UIKit

// The window used to run Java GUI programs (mod installers, jar files). Port of JavaGUIViewController.m.
// The JNI parts (AWTInputBridge_*, AWTScreenBridge_copyCurrentScreen) live in AWTInputBridge.m.

private let SPECIALBTN_LOGOUTPUT: Int32 = -100

// java.awt.event.InputEvent masks (utils.h defines these as "1 << 10", which Swift does not import)
private let AWT_BUTTON1_DOWN_MASK: Int32 = 1 << 10
private let AWT_BUTTON2_DOWN_MASK: Int32 = 1 << 11
private let AWT_BUTTON3_DOWN_MASK: Int32 = 1 << 12

private var shouldHitEnterAfterWindowShown = false
private var activeSurfaceView: SurfaceView?

// MARK: - SurfaceView

@objc(SurfaceView)
class SurfaceView: UIView {
    private var colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    // Owned by AWTInputBridge.m, only valid after the first successful refreshBuffer
    private var rgbArray: UnsafePointer<Int32>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.isOpaque = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.isOpaque = true
    }

    // Called by the display link, on a background thread
    @objc func refreshBuffer() {
        guard let pixels = AWTScreenBridge_copyCurrentScreen() else {
            return
        }
        rgbArray = pixels

        DispatchQueue.main.async {
            activeSurfaceView?.displayLayer()
        }

        // Wait until something renders at the middle
        let width = Int(windowWidth)
        let height = Int(windowHeight)
        if shouldHitEnterAfterWindowShown && pixels[width / 2 + width * height / 2] != 0 {
            shouldHitEnterAfterWindowShown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                // Auto hit Enter to install immediately
                AWTInputBridge_sendKey(10) // '\n'
            }
        }
    }

    @objc func displayLayer() {
        guard let rgbArray = rgbArray else {
            return
        }
        let width = Int(windowWidth)
        let height = Int(windowHeight)
        guard let bitmapProvider = CGDataProvider(
            dataInfo: nil,
            data: rgbArray,
            size: width * height * 4,
            releaseData: { _, _, _ in }
        ) else {
            return
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let bitmap = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4 * width,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: bitmapProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        layer.contents = bitmap
    }
}

// MARK: - ScrollableSurfaceView

private class ScrollableSurfaceView: UIScrollView, UIScrollViewDelegate {
    var clickRange: CGRect = .zero
    var virtualMouseFrame: CGRect = .zero
    var mousePointerView: UIImageView
    var shouldTriggerClick = false
    private let contentSurface: SurfaceView

    override init(frame: CGRect) {
        contentSurface = SurfaceView(frame: frame)
        activeSurfaceView = contentSurface
        mousePointerView = UIImageView(frame: .zero)
        super.init(frame: frame)
        addSubview(contentSurface)
        delegate = self

        virtualMouseFrame = CGRect(x: frame.size.width / 2, y: frame.size.height / 2, width: 18, height: 27)
        mousePointerView.frame = virtualMouseFrame
        mousePointerView.isHidden = !virtualMouseEnabled
        mousePointerView.image = UIImage(named: "MousePointer")
        contentSurface.addSubview(mousePointerView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var surface: SurfaceView {
        return contentSurface
    }

    private func awtScreenScale() -> CGFloat {
        return UIScreen.main.scale * CGFloat(getPrefFloat("video.resolution")) / 100.0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let location = touches.first?.location(in: self) else {
            return
        }
        clickRange = CGRect(x: location.x - 2, y: location.y - 2, width: 5, height: 5)
        shouldTriggerClick = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touchEvent = touches.first else {
            return
        }
        var location = touchEvent.location(in: self)
        if shouldTriggerClick && !clickRange.contains(location) {
            shouldTriggerClick = false
        }

        if virtualMouseEnabled {
            let prevLocation = touchEvent.previousLocation(in: self)
            // Calculate delta
            location.x = (location.x - prevLocation.x) / zoomScale
            location.y = (location.y - prevLocation.y) / zoomScale
            // Update cursor's origin
            virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x + location.x, 0, frame.size.width * zoomScale)
            virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y + location.y, 0, frame.size.height * zoomScale)
            mousePointerView.frame = virtualMouseFrame
            location = virtualMouseFrame.origin

            let minimumContentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            let maximumContentOffset = CGPoint(
                x: max(minimumContentOffset.x, contentSize.width + contentInset.right - frame.size.width),
                y: max(minimumContentOffset.y, contentSize.height + contentInset.bottom - frame.size.height))
            // Focus scroll view's content area on virtual mouse
            contentOffset = CGPoint(
                x: clamp(virtualMouseFrame.origin.x * zoomScale - center.x, minimumContentOffset.x, maximumContentOffset.x),
                y: clamp(virtualMouseFrame.origin.y * zoomScale - center.y, minimumContentOffset.y, maximumContentOffset.y))
        }

        // Send cursor position to AWT
        let screenScale = awtScreenScale()
        AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_CURSOR_POS), Int32(location.x * screenScale), Int32(location.y * screenScale), 0, 0)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if virtualMouseEnabled {
            // Keep virtual mouse in the middle of screen while zooming
            virtualMouseFrame.origin.x = (contentOffset.x + center.x) / zoomScale
            virtualMouseFrame.origin.y = (contentOffset.y + center.y) / zoomScale
            mousePointerView.frame = virtualMouseFrame
            // Send cursor position to AWT
            let screenScale = awtScreenScale()
            AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_CURSOR_POS),
                                          Int32(virtualMouseFrame.origin.x * screenScale),
                                          Int32(virtualMouseFrame.origin.y * screenScale), 0, 0)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return activeSurfaceView
    }
}

// MARK: - JavaGUIViewController

@objc(JavaGUIViewController)
class JavaGUIViewController: UIViewController, UIGestureRecognizerDelegate, UITextFieldDelegate {
    @objc var filepath: String?

    private var inputTextField: TrackedTextField!
    private var ctrlView: ControlLayout!
    private var logOutputView: PLLogOutputView!
    private var surfaceScrollView: ScrollableSurfaceView!

    private var _requiredJavaVersion = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        virtualMouseEnabled = getPrefBool("control.virtmouse_enable")

        let screenBounds = view.bounds
        let screenScale = UIScreen.main.scale * CGFloat(getPrefFloat("video.resolution")) / 100.0
        windowWidth = Int32((screenBounds.size.width * screenScale).rounded())
        windowHeight = Int32((screenBounds.size.height * screenScale).rounded())
        // Resolution should not be odd
        if windowWidth % 2 != 0 {
            windowWidth -= 1
        }
        if windowHeight % 2 != 0 {
            windowHeight -= 1
        }

        surfaceScrollView = ScrollableSurfaceView(frame: view.frame)
        surfaceScrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        surfaceScrollView.minimumZoomScale = 1
        surfaceScrollView.maximumZoomScale = 5
        surfaceScrollView.isScrollEnabled = false
        view.addSubview(surfaceScrollView)

        inputTextField = TrackedTextField(frame: CGRect(x: 0, y: -32.0, width: view.frame.size.width, height: 30.0))
        inputTextField.backgroundColor = .secondarySystemBackground
        inputTextField.delegate = self
        inputTextField.font = UIFont(name: "Menlo-Regular", size: 20)
        inputTextField.clearsOnBeginEditing = true
        inputTextField.textAlignment = .center
        inputTextField.sendChar = { keychar in
            AWTInputBridge_sendChar(keychar)
        }
        inputTextField.sendKey = { key, scancode, action, mods in
            if action == 0 { return }
            switch key {
            case Int32(GLFW_KEY_BACKSPACE):
                AWTInputBridge_sendKey(8) // '\b' VK_BACK_SPACE
            case Int32(GLFW_KEY_ENTER):
                AWTInputBridge_sendKey(10) // '\n' VK_ENTER
            case Int32(GLFW_KEY_DPAD_LEFT):
                AWTInputBridge_sendKey(0xE2) // VK_KP_LEFT
            case Int32(GLFW_KEY_DPAD_RIGHT):
                AWTInputBridge_sendKey(0xE3) // VK_KP_RIGHT
            default:
                break
            }
        }
        view.addSubview(inputTextField)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(surfaceOnClick(_:)))
        tapGesture.delegate = self
        tapGesture.numberOfTapsRequired = 1
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.cancelsTouchesInView = false
        surfaceScrollView.surface.addGestureRecognizer(tapGesture)

        // Borrowing custom controls, might be useful later (full-blown jar launcher with control support?)
        ctrlView = ControlLayout(frame: view.frame.inset(by: view.safeAreaInsets))
        view.addSubview(ctrlView)
        loadCustomControls()

        logOutputView = PLLogOutputView(frame: view.frame)
        if let navController = logOutputView.navController {
            navController.additionalSafeAreaInsets = view.safeAreaInsets
            addChild(navController)
            view.addSubview(navController.view)
        }

        setenv("AME_SKIP_JNI_GLFW", "1", 1)

        // Register the display loop
        let displayTarget = surfaceScrollView.surface
        DispatchQueue.global(qos: .default).async {
            let displayLink = CADisplayLink(target: displayTarget, selector: #selector(SurfaceView.refreshBuffer))
            if #available(iOS 15.0, *) {
                if getPrefBool("video.max_framerate") {
                    displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                } else {
                    displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                }
            }
            displayLink.add(to: RunLoop.current, forMode: .common)
            RunLoop.current.run()
        }

        DispatchQueue.global(qos: .default).async { [weak self] in
            guard let self = self else { return }
            _ = launchJVM(nil, self.filepath, windowWidth, windowHeight, Int32(truncatingIfNeeded: self._requiredJavaVersion))
            self._requiredJavaVersion = 0
        }
    }

    private func makeButton(_ name: String, _ keycode: Int32, _ x: String, _ y: String) -> NSMutableDictionary {
        var keycodes: [Int32] = [keycode, 0, 0, 0]
        return createButton(name, &keycodes, x, y, 80.0, 30.0)
    }

    private func loadCustomControls() {
        let dict = NSMutableDictionary()
        dict.setObject(NSNumber(value: 4), forKey: "version" as NSString)
        dict.setObject(NSNumber(value: 100), forKey: "scaledAt" as NSString)
        let controlList = NSMutableArray()
        dict.setObject(controlList, forKey: "mControlDataList" as NSString)

        controlList.add(makeButton("Keyboard", Int32(SPECIALBTN_KEYBOARD),
                                   "${margin}", "${margin}"))
        controlList.add(makeButton(localize("game.menu.log_output"), SPECIALBTN_LOGOUTPUT,
                                   "${right} - ${margin}", "${margin}"))
        controlList.add(makeButton("Mouse", Int32(SPECIALBTN_VIRTUALMOUSE),
                                   "${right} - ${margin}", "${margin} * 2 + ${height}"))
        controlList.add(makeButton("PRI", Int32(SPECIALBTN_MOUSEPRI),
                                   "${margin}", "${bottom} - ${margin}"))
        controlList.add(makeButton("SEC", Int32(SPECIALBTN_MOUSESEC),
                                   "${margin} * 2 + ${width}", "${bottom} - ${margin}"))
        ctrlView.loadControlLayout(dict)

        // Implement a subset of custom controls functionalites enough for few buttons
        for case let button as ControlButton in ctrlView.subviews {
            button.addTarget(self, action: #selector(executebtn_down(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(executebtn_up(_:)), for: [.touchUpInside, .touchUpOutside])
        }
    }

    // MARK: - Required Java version

    // 0 means "unknown/error". Computed from the jar's main class the first time it is asked for.
    @objc var requiredJavaVersion: Int {
        if _requiredJavaVersion != 0 {
            return _requiredJavaVersion
        }

        guard let filepath = filepath else {
            return 0
        }

        let archive: UZKArchive
        let manifestData: Data
        do {
            archive = try UZKArchive(path: filepath)
            manifestData = try archive.extractData(fromFile: "META-INF/MANIFEST.MF")
        } catch {
            showErrorMessage(error.localizedDescription)
            _requiredJavaVersion = 0
            return 0
        }

        let manifestStr = String(data: manifestData, encoding: .utf8) ?? ""
        let manifestLines = manifestStr.components(separatedBy: .newlines)
        var mainClass: String?
        for line in manifestLines where line.hasPrefix("Main-Class: ") {
            mainClass = String(line.dropFirst(12))
            break
        }
        guard let mainClassName = mainClass else {
            showErrorMessage(String(format: localize("java.error.missing_main_class"),
                                    (filepath as NSString).lastPathComponent))
            _requiredJavaVersion = 0
            return 0
        }
        let mainClassPath = mainClassName.replacingOccurrences(of: ".", with: "/") + ".class"

        let mainClassData: Data
        do {
            mainClassData = try archive.extractData(fromFile: mainClassPath)
        } catch {
            showErrorMessage(error.localizedDescription)
            _requiredJavaVersion = 0
            return 0
        }

        // Class file header: u4 magic, u2 minor, u2 major (big endian)
        let bytes = [UInt8](mainClassData.prefix(8))
        let magic: UInt32 = bytes.count >= 4
            ? (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            : 0
        if magic != 0xCAFEBABE {
            showErrorMessage(String(format: "Invalid magic number: 0x%x", magic))
            _requiredJavaVersion = 0
            return 0
        }
        if bytes.count < 8 {
            showErrorMessage("Invalid class file: truncated header")
            _requiredJavaVersion = 0
            return 0
        }

        let minorVer = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])
        let majorVer = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        NSLog("[ModInstaller] Main class version: %u.%u", UInt32(majorVer), UInt32(minorVer))

        _requiredJavaVersion = max(2, Int(majorVer) - 44)
        return _requiredJavaVersion
    }

    private func showErrorMessage(_ message: String) {
        activeSurfaceView = nil
        showDialog(localize("Error"), message)
    }

    @objc func setHitEnterAfterWindowShown(_ hitEnter: Bool) {
        shouldHitEnterAfterWindowShown = hitEnter
    }

    // MARK: - Buttons

    private func executebtn(_ sender: ControlButton, withAction action: Int32) {
        let held = action == Int32(ACTION_DOWN)
        let heldValue: Int32 = held ? 1 : 0
        let keycodes = sender.properties.object(forKey: "keycodes") as? NSArray
        for i in 0..<4 {
            guard let keycodes = keycodes, i < keycodes.count,
                  let keycode = (keycodes[i] as? NSNumber)?.int32Value else {
                continue
            }
            if keycode < 0 {
                switch keycode {
                case Int32(SPECIALBTN_KEYBOARD):
                    if held { return }
                    toggleSoftKeyboard()

                case Int32(SPECIALBTN_MOUSEPRI):
                    AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_MOUSE_BUTTON), AWT_BUTTON1_DOWN_MASK, heldValue, 0, 0)

                case Int32(SPECIALBTN_MOUSEMID):
                    AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_MOUSE_BUTTON), AWT_BUTTON2_DOWN_MASK, heldValue, 0, 0)

                case Int32(SPECIALBTN_MOUSESEC):
                    AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_MOUSE_BUTTON), AWT_BUTTON3_DOWN_MASK, heldValue, 0, 0)

                case Int32(SPECIALBTN_VIRTUALMOUSE):
                    if held { break }
                    virtualMouseEnabled = !virtualMouseEnabled
                    surfaceScrollView.mousePointerView.isHidden = !virtualMouseEnabled
                    setPrefBool("control.virtmouse_enable", virtualMouseEnabled)

                case SPECIALBTN_LOGOUTPUT:
                    if held { break }
                    logOutputView.actionToggleLogOutput()

                default:
                    NSLog("Warning: button %@ sent unknown special keycode: %d", sender.titleLabel?.text ?? "", keycode)
                }
            } else if keycode > 0 {
                // unimplemented
            }
        }
    }

    @objc func executebtn_down(_ button: ControlButton) {
        executebtn(button, withAction: Int32(ACTION_DOWN))
    }

    @objc func executebtn_up(_ button: ControlButton) {
        executebtn(button, withAction: Int32(ACTION_UP))
    }

    @objc func surfaceOnClick(_ sender: UITapGestureRecognizer) {
        if !surfaceScrollView.shouldTriggerClick { return }
        if sender.state == .recognized {
            let screenScale = UIScreen.main.scale * CGFloat(getPrefFloat("video.resolution")) / 100.0
            let location = virtualMouseEnabled
                ? surfaceScrollView.virtualMouseFrame.origin
                : sender.location(in: sender.view)
            let x = location.x * screenScale
            let y = location.y * screenScale
            AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_CURSOR_POS), Int32(x), Int32(y), 0, 0)
            AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_MOUSE_BUTTON), AWT_BUTTON1_DOWN_MASK, 1, 0, 0)
            AWTInputBridge_nativeSendData(Int32(EVENT_TYPE_MOUSE_BUTTON), AWT_BUTTON1_DOWN_MASK, 0, 0, 0)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        inputTextField.sendKey?(Int32(GLFW_KEY_ENTER), 0, 1, 0)
        textField.text = ""
        return true
    }

    private func toggleSoftKeyboard() {
        if inputTextField.isFirstResponder {
            inputTextField.resignFirstResponder()
        } else {
            inputTextField.becomeFirstResponder()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self = self else { return }
            self.ctrlView.frame = self.view.frame.inset(by: self.view.safeAreaInsets)
            for case let button as ControlButton in self.ctrlView.subviews {
                button.update()
            }
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            self.surfaceScrollView.virtualMouseFrame = self.surfaceScrollView.mousePointerView.frame
        })
        super.viewWillTransition(to: size, with: coordinator)
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return .bottom
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return false
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }
}
