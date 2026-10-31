import UIKit
import AVFoundation
import GameController

private let MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT: UInt32 = 6

private var currentHotbarSlot: Int32 = -1
private var pojavWindow: GameSurfaceView?
private var lastCenterPoint = CGPoint.zero

/// Target for the display link (the original used a block as the target and sent it `invoke`)
private final class InputTicker: NSObject {
    @objc func tick() {
        GyroInput.tick()
        ControllerInput.tick()
    }
}

private func controlProperty(_ button: ControlButton, _ key: String) -> Any? {
    return button.properties?.object(forKey: key)
}

private func controlFlag(_ button: ControlButton, _ key: String) -> Bool {
    return (controlProperty(button, key) as? NSNumber)?.boolValue ?? false
}

private func controlKeycode(_ button: ControlButton, at index: Int) -> Int32 {
    guard let codes = controlProperty(button, "keycodes") as? [Any], index < codes.count else { return 0 }
    return (codes[index] as? NSNumber)?.int32Value ?? 0
}

@objc(SurfaceViewController)
@objcMembers
class SurfaceViewController: UIViewController, UITextFieldDelegate, UIGestureRecognizerDelegate,
                             UITableViewDataSource, UITableViewDelegate {
    // Public to the rest of the app (the old header's properties)
    var ctrlView: ControlLayout!
    var surfaceView: GameSurfaceView!
    var touchView: UIView!
    var mousePointerView: UIImageView!
    var scrollPanGesture: UIPanGestureRecognizer!
    var rootView: UIView!

    // LogView category
    var logOutputView: PLLogOutputView!

    // Navigation category
    var menuArray: [String] = []
    var menuView: UITableView!
    var edgeGesture: UIScreenEdgePanGestureRecognizer!

    // Class extension
    var metadata: NSDictionary?

    var inputTextField: TrackedTextField!
    var swipeableButtons: [ControlButton] = []
    var swipingButton: ControlButton?
    var primaryTouch: UITouch?
    var hotbarTouch: UITouch?

    var longPressGesture: UILongPressGestureRecognizer!
    var longPressTwoGesture: UILongPressGestureRecognizer!
    var tapGesture: UITapGestureRecognizer!
    var doubleTapGesture: UITapGestureRecognizer!

    var mouseConnectCallback: Any?
    var mouseDisconnectCallback: Any?
    var controllerConnectCallback: Any?
    var controllerDisconnectCallback: Any?

    var screenScale: CGFloat = 0
    var mouseSpeed: CGFloat = 0
    var clickRange = CGRect.zero
    var isMacCatalystApp = false
    var shouldHideControlsFromRecording = false
    var shouldTriggerClick = false
    var shouldTriggerHaptic = false
    var slideableHotbar = false
    var toggleHidden = false

    var enableMouseGestures = false
    var enableHotbarGestures = false

    var lightHaptic: UIImpactFeedbackGenerator!
    var mediumHaptic: UIImpactFeedbackGenerator!

    // Class-level API used by the Obj-C core (+surface, +isRunning)
    static var surface: GameSurfaceView? {
        return pojavWindow
    }

    static var isRunning: Bool {
        return UIWindow.mainWindow()?.rootViewController is SurfaceViewController
    }

    @objc(initWithMetadata:)
    init(metadata: NSDictionary?) {
        self.metadata = metadata
        super.init(nibName: nil, bundle: nil)
    }

    /// `[[SurfaceViewController alloc] init]` (ios_uikit_bridge.m)
    convenience init() {
        self.init(metadata: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        isControlModifiable = false
        isMacCatalystApp = ProcessInfo.processInfo.isMacCatalystApp
        // Load MetalHUD library
        _ = dlopen("/usr/lib/libMTLHud.dylib", 0)

        lightHaptic = UIImpactFeedbackGenerator(style: .light)
        mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

        //setPrefBool("internal.internal_launch_on_boot", false)

        UIApplication.shared.isIdleTimerDisabled = true
        let isTVOS = realUIIdiom == .tv
        if !isTVOS {
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        }

        // Perform Gamepad joystick ticking, while also controlling frame rate?
        let displayLink = CADisplayLink(target: InputTicker(), selector: #selector(InputTicker.tick))
        if #available(iOS 15.0, tvOS 15.0, *) {
            if getPrefBool("video.max_framerate") {
                displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            } else {
                displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            }
        }
        displayLink.add(to: RunLoop.current, forMode: .common)

        let screenScale = UIScreen.main.scale

        updateSavedResolution()

        rootView = UIView(frame: CGRect(x: 0, y: 0, width: view.frame.size.width + 30.0, height: view.frame.size.height))
        view.addSubview(rootView)

        ctrlView = ControlLayout(frame: getSafeArea(view.frame))

        initCategory_Navigation()

        surfaceView = GameSurfaceView(frame: view.frame)
        surfaceView.layer.contentsScale = screenScale
        surfaceView.layer.magnificationFilter = .nearest
        surfaceView.layer.minificationFilter = .nearest
        surfaceView.isMultipleTouchEnabled = true
        pojavWindow = surfaceView

        touchView = UIView(frame: view.frame)
        touchView.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
        touchView.isMultipleTouchEnabled = true
        touchView.addSubview(surfaceView)

        rootView.addSubview(touchView)
        rootView.addSubview(ctrlView)

        setupCategory_Navigation()

        let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(surfaceOnHover(_:)))
        touchView.addGestureRecognizer(hoverGesture)

        let directTouch = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        tapGesture = UITapGestureRecognizer(target: self, action: #selector(surfaceOnClick(_:)))
        tapGesture.allowedTouchTypes = directTouch
        tapGesture.delegate = self
        tapGesture.numberOfTapsRequired = 1
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.cancelsTouchesInView = false
        touchView.addGestureRecognizer(tapGesture)

        doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(surfaceOnDoubleClick(_:)))
        doubleTapGesture.allowedTouchTypes = directTouch
        doubleTapGesture.delegate = self
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.numberOfTouchesRequired = 1
        doubleTapGesture.cancelsTouchesInView = false
        touchView.addGestureRecognizer(doubleTapGesture)

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(surfaceOnLongpress(_:)))
        longPressGesture.allowedTouchTypes = directTouch
        longPressGesture.cancelsTouchesInView = false
        longPressGesture.delegate = self
        touchView.addGestureRecognizer(longPressGesture)

        longPressTwoGesture = UILongPressGestureRecognizer(target: self, action: #selector(keyboardGesture(_:)))
        longPressTwoGesture.numberOfTouchesRequired = 2
        longPressTwoGesture.allowedTouchTypes = directTouch
        longPressTwoGesture.cancelsTouchesInView = false
        longPressTwoGesture.delegate = self
        touchView.addGestureRecognizer(longPressTwoGesture)

        scrollPanGesture = UIPanGestureRecognizer(target: self, action: #selector(surfaceOnTouchesScroll(_:)))
        scrollPanGesture.allowedTouchTypes = directTouch
        scrollPanGesture.delegate = self
        scrollPanGesture.minimumNumberOfTouches = 2
        scrollPanGesture.maximumNumberOfTouches = 2
        touchView.addGestureRecognizer(scrollPanGesture)

        // Virtual mouse
        virtualMouseEnabled = getPrefBool("control.virtmouse_enable")
        virtualMouseFrame = CGRect(x: view.frame.size.width / 2, y: view.frame.size.height / 2, width: 18, height: 27)
        mousePointerView = UIImageView(frame: virtualMouseFrame)
        mousePointerView.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin, .flexibleRightMargin, .flexibleBottomMargin]
        mousePointerView.isHidden = !virtualMouseEnabled
        mousePointerView.image = UIImage(named: "MousePointer")
        mousePointerView.isUserInteractionEnabled = false
        touchView.addSubview(mousePointerView)

        inputTextField = TrackedTextField(frame: CGRect(x: 0, y: -32.0, width: view.frame.size.width, height: 30.0))
        inputTextField.backgroundColor = UIColor.secondarySystemBackground
        inputTextField.delegate = self
        inputTextField.font = UIFont(name: "Menlo-Regular", size: 20)
        inputTextField.clearsOnBeginEditing = true
        inputTextField.textAlignment = .center
        inputTextField.sendChar = { keychar in
            _ = CallbackBridge_nativeSendChar(keychar)
        }
        inputTextField.sendCharMods = { keychar, mods in
            _ = CallbackBridge_nativeSendCharMods(keychar, mods)
        }
        inputTextField.sendKey = { key, scancode, action, mods in
            CallbackBridge_nativeSendKey(key, scancode, action, mods)
        }

        swipeableButtons = []

        KeyboardInput.initKeycodeTable()
        mouseConnectCallback = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: OperationQueue.main) { [weak self] note in
            guard let self = self else { return }
            NSLog("Input: Mouse connected!")
            if let mouse = note.object as? GCMouse {
                self.registerMouseCallbacks(mouse)
            }
            self.mousePointerView.isHidden = isGrabbing != 0 || !virtualMouseEnabled
            self.setNeedsUpdateOfPrefersPointerLocked()
        }
        mouseDisconnectCallback = NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: OperationQueue.main) { [weak self] note in
            guard let self = self else { return }
            NSLog("Input: Mouse disconnected!")
            if let mouse = note.object as? GCMouse {
                mouse.mouseInput?.mouseMovedHandler = nil
                mouse.mouseInput?.leftButton.pressedChangedHandler = nil
                mouse.mouseInput?.middleButton?.pressedChangedHandler = nil
                mouse.mouseInput?.rightButton?.pressedChangedHandler = nil
                for button in mouse.mouseInput?.auxiliaryButtons ?? [] {
                    button.pressedChangedHandler = nil
                }
            }
            self.setNeedsUpdateOfPrefersPointerLocked()
            if getPrefBool("controll.hardware_hide") {
                self.ctrlView.isHidden = false
            }
        }
        if let currentMouse = GCMouse.current {
            registerMouseCallbacks(currentMouse)
        }

        // TODO: deal with multiple controllers by letting users decide which one to use?
        controllerConnectCallback = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: OperationQueue.main) { [weak self] note in
            guard let self = self else { return }
            NSLog("Input: Controller connected!")
            if let controller = note.object as? GCController {
                ControllerInput.initKeycodeTable()
                ControllerInput.registerControllerCallbacks(controller)
            }
            self.mousePointerView.isHidden = isGrabbing != 0
            virtualMouseEnabled = true
            if getPrefBool("control.hardware_hide") {
                self.ctrlView.isHidden = true
            }
        }
        controllerDisconnectCallback = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: OperationQueue.main) { [weak self] note in
            guard let self = self else { return }
            NSLog("Input: Controller disconnected!")
            if let controller = note.object as? GCController {
                ControllerInput.unregisterControllerCallbacks(controller)
            }
            if getPrefBool("control.hardware_hide") {
                self.ctrlView.isHidden = false
            }
        }
        if GCController.controllers().count == 1 {
            ControllerInput.initKeycodeTable()
            ControllerInput.registerControllerCallbacks(GCController.controllers()[0])
        }

        rootView.addSubview(inputTextField)

        initCategory_LogView()

        // setPreferredFramesPerSecond(1000)
        updateJetsamControl()
        updatePreferenceChanges()
        loadCustomControls()

        if UIApplication.shared.connectedScenes.count > 1 &&
            getPrefBool("video.fullscreen_airplay") {
            switchToExternalDisplay()
        }

        launchMinecraft()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfPrefersPointerLocked()
    }

    func updateAudioSettings() {
        let category: AVAudioSession.Category
        var options: AVAudioSession.CategoryOptions = []
        if getPrefBool("video.allow_microphone") {
            category = .playAndRecord
            options.formUnion([.allowAirPlay, .allowBluetoothA2DP, .defaultToSpeaker])
        } else if getPrefBool("video.silence_with_switch") {
            category = .soloAmbient
        } else {
            category = .playback
        }
        if !getPrefBool("video.silence_other_audio") {
            options.insert(.mixWithOthers)
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(category, options: options)
        try? session.setActive(true)
    }

    func updateJetsamControl() {
        if !getEntitlementValue("com.apple.private.memorystatus") {
            return
        }
        // memorystatus_control is a private libsystem function with no header
        typealias MemoryStatusControl = @convention(c) (UInt32, Int32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "memorystatus_control") else { return }
        let memorystatusControl = unsafeBitCast(symbol, to: MemoryStatusControl.self)
        // More 1024MB is necessary for other memory regions (native, Java GC, etc.)
        let limit = Int32(truncatingIfNeeded: getPrefInt("java.allocated_memory")) &+ 1024
        if memorystatusControl(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), UInt32(bitPattern: limit), nil, 0) == -1 {
            NSLog("Failed to set Jetsam task limit: error: %s", strerror(errno))
        } else {
            NSLog("Successfully set Jetsam task limit")
        }
    }

    func updatePreferenceChanges() {
        // Update UITextField auto correction
        if getPrefBool("debug.debug_auto_correction") {
            inputTextField.autocorrectionType = .default
        } else {
            inputTextField.autocorrectionType = .no
        }

        let gyroEnabled = getPrefBool("control.gyroscope_enable")
        let gyroInvertX = getPrefBool("control.gyroscope_invert_x_axis")
        let gyroSensitivity = Int32(truncatingIfNeeded: getPrefInt("control.gyroscope_sensitivity"))
        GyroInput.updateSensitivity(gyroEnabled ? gyroSensitivity : 0, invertXAxis: gyroInvertX)

        mouseSpeed = CGFloat(getPrefFloat("control.mouse_speed") / 100.0)

        virtualMouseEnabled = getPrefBool("control.virtmouse_enable")
        mousePointerView.isHidden = isGrabbing != 0 || !virtualMouseEnabled

        // Update virtual mouse scale
        let mouseScale = CGFloat(getPrefFloat("control.mouse_scale") / 100.0)
        virtualMouseFrame = CGRect(x: view.frame.size.width / 2, y: view.frame.size.height / 2, width: 18.0 * mouseScale, height: 27 * mouseScale)
        mousePointerView.frame = virtualMouseFrame

        shouldHideControlsFromRecording = getPrefFloat("control.recording_hide") != 0
        ctrlView.hideViewFromCapture(shouldHideControlsFromRecording)
        ctrlView.frame = getSafeArea(view.frame)

        // Update gestures state
        slideableHotbar = getPrefBool("control.slideable_hotbar")
        enableMouseGestures = getPrefBool("control.gesture_mouse")
        enableHotbarGestures = getPrefBool("control.gesture_hotbar")
        shouldTriggerHaptic = !getPrefBool("control.disable_haptics")

        scrollPanGesture.isEnabled = enableMouseGestures
        doubleTapGesture.isEnabled = enableHotbarGestures
        longPressGesture.minimumPressDuration = TimeInterval(getPrefFloat("control.press_duration") / 1000.0)

        // Update audio settings
        updateAudioSettings()
        // Update resolution
        updateSavedResolution()
        // Update performance HUD visibility
        if #available(iOS 16, tvOS 16, *) {
            if let metalLayer = surfaceView.layer as? CAMetalLayer {
                let perfHUDEnabled = getPrefBool("video.performance_hud")
                metalLayer.developerHUDProperties = perfHUDEnabled ? ["mode": "default"] : nil
            }
        }
        // Update pointer lock state
        setNeedsUpdateOfPrefersPointerLocked()
    }

    func updateSavedResolution() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            screenScale = windowScene.screen.scale
            if windowScene.session.role != .windowApplication {
                break
            }
        }

        if let host = surfaceView?.superview {
            surfaceView.frame = host.frame
        }

        resolutionScale = getPrefFloat("video.resolution") / 100.0
        // ANGLE sizes its drawable from bounds * contentsScale and ignores drawableSize, MoltenVK compares the two
        let renderer = ame_renderer_from_name(getenv("AME_RENDERER"))
        let vulkanNative = ame_renderer_is_vulkan_native(renderer) || AMVulkanNativeActive()
        let scaledByLayer = ame_renderer_uses_angle(renderer) || vulkanNative
        surfaceView?.layer.contentsScale = scaledByLayer ? screenScale * CGFloat(resolutionScale) : screenScale

        let frameSize = surfaceView?.frame.size ?? .zero
        physicalWidth = Int32(Float(frameSize.width * screenScale).rounded())
        physicalHeight = Int32(Float(frameSize.height * screenScale).rounded())

        // Minecraft's internal render resolution.
        windowWidth = Int32((Float(physicalWidth) * resolutionScale).rounded())
        windowHeight = Int32((Float(physicalHeight) * resolutionScale).rounded())

        // Resolution should not be odd.
        if (windowWidth % 2) != 0 {
            windowWidth -= 1
        }
        if (windowHeight % 2) != 0 {
            windowHeight -= 1
        }

        if vulkanNative, let surfaceView = surfaceView {
            // must match what MoltenVK derives from the layer, see ame_vk_drawable_extent
            var w: UInt32 = 0
            var h: UInt32 = 0
            ame_vk_drawable_extent(Double(surfaceView.bounds.size.width), Double(surfaceView.bounds.size.height),
                                   Double(surfaceView.layer.contentsScale), &w, &h)
            windowWidth = Int32(truncatingIfNeeded: w)
            windowHeight = Int32(truncatingIfNeeded: h)
        }

        // the Vulkan driver owns drawableSize for Kosmic Krisp, only MoltenVK and ANGLE get it from here
        if let metalLayer = surfaceView?.layer as? CAMetalLayer, !ame_vulkan_driver_sizes_layer(renderer) {
            metalLayer.drawableSize = CGSize(width: CGFloat(max(windowWidth, 1)), height: CGFloat(max(windowHeight, 1)))
        }

        AmethystSDL3ApplyResolutionScale()

        // Tell Minecraft/MobileGL about the internal render resolution.
        CallbackBridge_nativeSendScreenSize(windowWidth, windowHeight)
    }

    func updateControlHiddenState(_ hide: Bool) {
        for view in ctrlView.subviews {
            guard let button = view as? ControlButton else { continue }
            if !button.canBeHidden { continue }
            let hidden = hide || !(
                (isGrabbing != 0 && controlFlag(button, "displayInGame")) ||
                (isGrabbing == 0 && controlFlag(button, "displayInMenu")))
            if !hidden && !(button is ControlSubButton) {
                button.isHidden = hidden
                if let drawer = button as? ControlDrawer {
                    drawer.restoreButtonVisibility()
                }
            } else if hidden {
                button.isHidden = hidden
            }
        }
    }

    func updateGrabState() {
        // Update cursor position
        if isGrabbing == 1 {
            let screenScale = self.screenScale
            CallbackBridge_nativeSendCursorPos(CChar(ACTION_DOWN), lastVirtualMousePoint.x * screenScale, lastVirtualMousePoint.y * screenScale)
            virtualMouseFrame.origin.x = view.frame.size.width / 2
            virtualMouseFrame.origin.y = view.frame.size.height / 2
            mousePointerView.frame = virtualMouseFrame
        }
        scrollPanGesture.isEnabled = isGrabbing == 0
        mousePointerView.isHidden = isGrabbing != 0 || !virtualMouseEnabled
        setNeedsUpdateOfPrefersPointerLocked()

        // Update buttons visibility
        updateControlHiddenState(false)
    }

    func launchMinecraft() {
        DispatchQueue.global(qos: .default).async {
            let javaVersion = self.metadata?.object(forKey: "javaVersion") as? NSDictionary
            var minVersion = (javaVersion?.object(forKey: "majorVersion") as? NSNumber)?.int32Value ?? 0
            if minVersion == 0 {
                minVersion = (javaVersion?.object(forKey: "version") as? NSNumber)?.int32Value ?? 0
            }
            _ = launchJVM(
                BaseAuthenticator.current.authData.object(forKey: "username") as? String,
                self.metadata,
                windowWidth, windowHeight,
                minVersion
            )
        }
    }

    func loadCustomControls() {
        edgeGesture.isEnabled = true
        swipeableButtons.removeAll()
        let controlFile = PLProfiles.resolveKeyForCurrentProfile("defaultTouchCtrl") as? String
        ctrlView.loadControlFile(controlFile)

        var menuButton: ControlButton?
        for view in ctrlView.subviews {
            guard let button = view as? ControlButton else { continue }
            let isSwipeable = controlFlag(button, "isSwipeable")

            button.canBeHidden = true
            for i in 0..<4 {
                let keycodeInt = controlKeycode(button, at: i)
                button.canBeHidden = button.canBeHidden && keycodeInt != SPECIALBTN_TOGGLECTRL && keycodeInt != SPECIALBTN_VIRTUALMOUSE
                if keycodeInt == SPECIALBTN_MENU {
                    menuButton = button
                }
            }

            button.addTarget(self, action: #selector(executebtn_down(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(executebtn_up_inside(_:)), for: .touchUpInside)
            button.addTarget(self, action: #selector(executebtn_up_outside(_:)), for: .touchUpOutside)

            if isSwipeable {
                let panRecognizerButton = UIPanGestureRecognizer(target: self, action: #selector(executebtn_swipe(_:)))
                panRecognizerButton.delegate = self
                button.addGestureRecognizer(panRecognizerButton)
                swipeableButtons.append(button)
            }
        }

        updateControlHiddenState(toggleHidden)

        if let menuButton = menuButton {
            var items: [UIMenuElement] = []
            for i in 0..<menuArray.count {
                let item = UIAction(title: localize(menuArray[i]), image: nil, identifier: nil) { [weak self] _ in
                    self?.didSelectMenuItem(Int32(i))
                }
                items.append(item)
            }
            menuButton.menu = UIMenu(title: "", image: nil, identifier: nil, options: .displayInline, children: items)
            menuButton.showsMenuAsPrimaryAction = true
            edgeGesture.isEnabled = false
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: { _ in
            self.rootView.bounds = CGRect(x: 0, y: 0, width: size.width + 30.0, height: size.height)

            var frame = self.view.frame
            frame.size = size
            self.touchView.frame = frame
            self.inputTextField.frame = CGRect(x: 0, y: -32.0, width: size.width, height: 30.0)
            self.viewWillTransitionToSize_Navigation(frame)

            // Update custom controls button position
            self.ctrlView.frame = getSafeArea(self.view.frame)
            for view in self.ctrlView.subviews {
                (view as? ControlButton)?.update()
            }

            // Update game resolution
            self.updateSavedResolution()
            GyroInput.updateOrientation()
        }, completion: { _ in
            virtualMouseFrame = self.mousePointerView.frame
        })
        super.viewWillTransition(to: size, with: coordinator)
    }

    // MARK: - Input: send touch utilities

    func isTouchInactive(_ touch: UITouch?) -> Bool {
        guard let touch = touch else { return true }
        return touch.phase == .ended || touch.phase == .cancelled
    }

    @objc(sendTouchPoint:withEvent:)
    func sendTouchPoint(_ location: CGPoint, withEvent eventIn: Int32) {
        var event = eventIn
        var screenScale = self.screenScale
        if isGrabbing == 0 {
            screenScale *= CGFloat(resolutionScale)
            if virtualMouseEnabled {
                if event == ACTION_MOVE {
                    virtualMouseFrame.origin.x += (location.x - lastVirtualMousePoint.x) * mouseSpeed
                    virtualMouseFrame.origin.y += (location.y - lastVirtualMousePoint.y) * mouseSpeed
                } else if event == ACTION_MOVE_MOTION {
                    event = ACTION_MOVE
                    virtualMouseFrame.origin.x += location.x * mouseSpeed
                    virtualMouseFrame.origin.y += location.y * mouseSpeed
                }
                virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x, 0, surfaceView.frame.size.width)
                virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y, 0, surfaceView.frame.size.height)
                lastVirtualMousePoint = location
                mousePointerView.frame = virtualMouseFrame
                CallbackBridge_nativeSendCursorPos(CChar(event), virtualMouseFrame.origin.x * screenScale, virtualMouseFrame.origin.y * screenScale)
                return
            }
            lastVirtualMousePoint = location
        }
        CallbackBridge_nativeSendCursorPos(CChar(event), location.x * screenScale, location.y * screenScale)
    }

    // MARK: - Input: on-surface functions

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func keyboardGesture(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer.state == .began {
            if inputTextField.isFirstResponder {
                inputTextField.resignFirstResponder()
                inputTextField.alpha = 1.0
            } else {
                inputTextField.becomeFirstResponder()
                // Insert an undeletable space
                inputTextField.text = " "
            }
        }
    }

    func sendTouchEvent(_ touchEvent: UITouch, withUIEvent uievent: UIEvent?, withEvent eventIn: Int32) {
        var event = eventIn
        var locationInView = touchEvent.location(in: rootView)

        //if touchEvent.view == surfaceView {
        switch event {
        case ACTION_DOWN:
            clickRange = CGRect(x: locationInView.x - 2, y: locationInView.y - 2, width: 5, height: 5)
            shouldTriggerClick = true

        case ACTION_MOVE:
            if shouldTriggerClick && !clickRange.contains(locationInView) {
                shouldTriggerClick = false
            }

        default:
            break
        }

        if touchEvent === hotbarTouch && slideableHotbar && !isTouchInactive(hotbarTouch) {
            let screenScale = UIScreen.main.scale
            let slot: Int32 = enableHotbarGestures ?
                callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1
            if slot != -1 && currentHotbarSlot != slot && (event == ACTION_DOWN || currentHotbarSlot != -1) {
                currentHotbarSlot = slot
                CallbackBridge_nativeSendKey(slot, 0, 1, 0)
                CallbackBridge_nativeSendKey(slot, 0, 0, 0)
                return
            } /* else if ((event == ACTION_MOVE || event == ACTION_UP) && slot == -1 && currentHotbarSlot != -1) {
                return;
            } */

            if event == ACTION_DOWN && slot == -1 {
                currentHotbarSlot = -1
            }
            /*
            if (currentHotbarSlot != -1) {
                return;
            }
            */
            return
        }

        if touchEvent === primaryTouch {
            if isTouchInactive(primaryTouch) { return } // FIXME: should be? ACTION_UP will never be sent
            if event == ACTION_MOVE && isGrabbing != 0 {
                event = ACTION_MOVE_MOTION
                let prevLocationInView = touchEvent.previousLocation(in: rootView)
                locationInView.x -= prevLocationInView.x
                locationInView.y -= prevLocationInView.y
            }
            sendTouchPoint(locationInView, withEvent: event)
        }
        //}
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            if let key = press.key, KeyboardInput.sendKeyEvent(key, down: true, textFieldActive: inputTextField.isFirstResponder) {
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            if let key = press.key, KeyboardInput.sendKeyEvent(key, down: false, textFieldActive: inputTextField.isFirstResponder) {
                handled = true
            }
        }

        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // a cancelled press never gets a pressesEnded, release the key or it stays down
        var handled = false

        for press in presses {
            if let key = press.key, KeyboardInput.sendKeyEvent(key, down: false, textFieldActive: inputTextField.isFirstResponder) {
                handled = true
            }
        }

        if !handled {
            super.pressesCancelled(presses, with: event)
        }
    }

    override var prefersPointerLocked: Bool {
        return GCMouse.mice().count > 0 && (isGrabbing != 0 || virtualMouseEnabled)
    }

    func registerMouseCallbacks(_ mouse: GCMouse) {
        NSLog("Input: Got mouse %@", mouse)
        guard let mouseInput = mouse.mouseInput else { return }
        mouseInput.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self = self else { return }
            if self.view.window?.windowScene?.pointerLockState?.isLocked != true {
                return
            }
            self.sendTouchPoint(CGPoint(x: CGFloat(deltaX), y: CGFloat(-deltaY)), withEvent: ACTION_MOVE_MOTION)
        }

        mouseInput.leftButton.pressedChangedHandler = { _, _, pressed in
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed ? 1 : 0, 0)
        }
        mouseInput.middleButton?.pressedChangedHandler = { _, _, pressed in
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed ? 1 : 0, 0)
        }
        mouseInput.rightButton?.pressedChangedHandler = { _, _, pressed in
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed ? 1 : 0, 0)
        }
        // GLFW can handle up to 8 mouse buttons, the first 3 buttons are reserved for left,middle,right
        let auxiliaryButtons = mouseInput.auxiliaryButtons ?? []
        for i in 0..<min(auxiliaryButtons.count, 5) {
            auxiliaryButtons[i].pressedChangedHandler = { _, _, pressed in
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_4 + Int32(i), pressed ? 1 : 0, 0)
            }
        }

        mouseInput.scroll.xAxis.valueChangedHandler = { _, value in
            // Workaround MC-121772 (macOS/iOS feature)
            CallbackBridge_nativeSendScroll(CGFloat(value), CGFloat(value))
        }
        mouseInput.scroll.yAxis.valueChangedHandler = { _, value in
            // Workaround MC-121772 (macOS/iOS feature)
            CallbackBridge_nativeSendScroll(CGFloat(-value), CGFloat(-value))
        }

        if getPrefBool("control.hardware_hide") {
            ctrlView.isHidden = true
        }
    }

    func surfaceOnClick(_ sender: UITapGestureRecognizer) {
        if sender.state == .began || sender.state == .ended {
            if shouldTriggerHaptic {
                lightHaptic.impactOccurred()
            }
        }

        if !shouldTriggerClick { return }

        if sender.state == .recognized {
            if currentHotbarSlot == -1 {
                if !enableMouseGestures { return }
                CallbackBridge_nativeSendMouseButton(isGrabbing == 1 ?
                    GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 1, 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) {
                    CallbackBridge_nativeSendMouseButton(isGrabbing == 1 ?
                        GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 0, 0)
                }
            } else {
                CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 1, 0)
                CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 0, 0)
            }
        }
    }

    func surfaceOnDoubleClick(_ sender: UITapGestureRecognizer) {
        if sender.state == .began || sender.state == .ended {
            if shouldTriggerHaptic {
                lightHaptic.impactOccurred()
            }
        }

        if sender.state == .recognized && isGrabbing != 0 {
            let screenScale = UIScreen.main.scale
            let point = sender.location(in: rootView)
            let hotbarSlot: Int32 = enableHotbarGestures ?
                callback_SurfaceViewController_touchHotbar(point.x * screenScale, point.y * screenScale) : -1
            if hotbarSlot != -1 && currentHotbarSlot == hotbarSlot {
                CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 1, 0)
                CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 0, 0)
            }
        }
    }

    func surfaceOnHover(_ sender: UIGestureRecognizer) {
        if isGrabbing != 0 { return }

        let point = sender.location(in: rootView)
        // NSLog("Mouse move!!")
        // NSLog("Mouse pos = %f, %f", point.x, point.y)
        switch sender.state {
        case .began:
            sendTouchPoint(point, withEvent: ACTION_DOWN)
        case .changed:
            sendTouchPoint(point, withEvent: ACTION_MOVE)
        case .ended, .cancelled:
            sendTouchPoint(point, withEvent: ACTION_UP)
        default:
            // point = CGPointMake(-1, -1);
            break
        }
    }

    func surfaceOnLongpress(_ sender: UILongPressGestureRecognizer) {
        if sender.state == .began || sender.state == .ended {
            if shouldTriggerHaptic {
                mediumHaptic.impactOccurred()
            }
        }

        if !slideableHotbar {
            let location = sender.location(in: rootView)
            let screenScale = UIScreen.main.scale
            currentHotbarSlot = enableHotbarGestures ?
                callback_SurfaceViewController_touchHotbar(location.x * screenScale, location.y * screenScale) : -1
        }
        if sender.state == .began {
            shouldTriggerClick = false
            if currentHotbarSlot == -1 {
                if enableMouseGestures {
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 1, 0)
                }
            } else {
                CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 1, 0)
            }
        } else if sender.state == .changed {
            // Nothing to do here, already handled in touchesMoved
        } else if sender.state == .cancelled
                    || sender.state == .failed
                    || sender.state == .ended {
            if currentHotbarSlot == -1 {
                if enableMouseGestures {
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 0, 0)
                }
            } else {
                CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 0, 0)
            }
        }
    }

    func surfaceOnTouchesScroll(_ sender: UIPanGestureRecognizer) {
        if sender.state == .began || sender.state == .ended {
            if shouldTriggerHaptic {
                lightHaptic.impactOccurred()
            }
        }

        if isGrabbing != 0 { return }
        if sender.state == .began ||
            sender.state == .changed ||
            sender.state == .ended {
            let velocity = sender.velocity(in: rootView)
            if velocity.x != 0.0 || velocity.y != 0.0 {
                CallbackBridge_nativeSendScroll(velocity.x / view.frame.size.width, velocity.y / view.frame.size.height)
            }
        }
    }

    // MARK: - Input view stuff

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 1, 0)
        CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 0, 0)
        textField.text = " "
        return true
    }

    // MARK: - On-screen button functions

    func executebtn(_ sender: ControlButton?, withAction action: Int32) {
        guard let sender = sender else { return }
        let held: Int32 = action == ACTION_DOWN ? 1 : 0
        for i in 0..<4 {
            let keycode = controlKeycode(sender, at: i)
            if keycode < 0 {
                switch keycode {
                case SPECIALBTN_KEYBOARD:
                    if held == 0 {
                        if inputTextField.isFirstResponder {
                            inputTextField.resignFirstResponder()
                            inputTextField.alpha = 1.0
                        } else {
                            inputTextField.becomeFirstResponder()
                            // Insert an undeletable space
                            inputTextField.text = " "
                        }
                    }

                case SPECIALBTN_MOUSEPRI:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, held, 0)

                case SPECIALBTN_MOUSESEC:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, held, 0)

                case SPECIALBTN_MOUSEMID:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, held, 0)

                case SPECIALBTN_TOGGLECTRL:
                    executebtn_special_togglebtn(held)

                case SPECIALBTN_SCROLLDOWN:
                    if held == 0 {
                        CallbackBridge_nativeSendScroll(0.0, 1.0)
                    }

                case SPECIALBTN_SCROLLUP:
                    if held == 0 {
                        CallbackBridge_nativeSendScroll(0.0, -1.0)
                    }

                case SPECIALBTN_VIRTUALMOUSE:
                    if isGrabbing == 0 && held == 0 {
                        virtualMouseEnabled = !virtualMouseEnabled
                        mousePointerView.isHidden = !virtualMouseEnabled
                        setPrefBool("control.virtmouse_enable", virtualMouseEnabled)
                        setNeedsUpdateOfPrefersPointerLocked()
                    }

                case SPECIALBTN_MENU:
                    if held == 0 {
                        actionOpenNavigationMenu()
                    }

                default:
                    NSLog("Warning: button %@ sent unknown special keycode: %d", sender.titleLabel?.text ?? "(null)", keycode)
                }
            } else if keycode > 0 {
                // there's no key id 0, but we accidentally used -1 as a special key id, so we had to do that
                // if (keycode == 0) { keycode = -1; }
                // at the moment, send unknown keycode does nothing, may even cause performance issue, so ignore it
                CallbackBridge_nativeSendKey(keycode, 0, held, 0)
            }
        }
    }

    func executebtn_down(_ sender: ControlButton) {
        if shouldTriggerHaptic {
            lightHaptic.impactOccurred()
        }

        if sender.savedBackgroundColor == nil {
            executebtn(sender, withAction: ACTION_DOWN)
        }
        if swipeableButtons.contains(sender) {
            swipingButton = sender
        }
    }

    func executebtn_swipe(_ sender: UIPanGestureRecognizer) {
        if sender.state == .cancelled || sender.state == .ended {
            executebtn_up(swipingButton, isOutside: false)
            return
        }
        let location = sender.location(in: ctrlView)
        for button in swipeableButtons {
            if button.frame.contains(location) && swipingButton !== button {
                executebtn_up(swipingButton, isOutside: false)
                swipingButton = button
                executebtn(swipingButton, withAction: ACTION_DOWN)
                break
            }
        }
    }

    func executebtn_up(_ sender: ControlButton?, isOutside: Bool) {
        if swipingButton === sender {
            executebtn(swipingButton, withAction: ACTION_UP)
            swipingButton = nil
        } else if sender?.savedBackgroundColor == nil {
            executebtn(sender, withAction: ACTION_UP)
            return
        }

        guard let sender = sender else { return }
        if isOutside || sender.savedBackgroundColor == nil {
            return
        }

        sender.isToggleOn = !sender.isToggleOn
        if sender.isToggleOn {
            sender.backgroundColor = view.tintColor.withAlphaComponent(sender.savedBackgroundColor.cgColor.alpha)
            executebtn(sender, withAction: ACTION_DOWN)
        } else {
            sender.backgroundColor = sender.savedBackgroundColor
            executebtn(sender, withAction: ACTION_UP)
        }

        if shouldTriggerHaptic {
            lightHaptic.impactOccurred()
        }
    }

    func executebtn_up_inside(_ sender: ControlButton) {
        executebtn_up(sender, isOutside: false)
    }

    func executebtn_up_outside(_ sender: ControlButton) {
        executebtn_up(sender, isOutside: true)
    }

    func executebtn_special_togglebtn(_ held: Int32) {
        if held != 0 { return }
        toggleHidden = !toggleHidden
        updateControlHiddenState(toggleHidden)
    }

    // MARK: - Input: On-screen touch events

    // Equals to Android ACTION_DOWN
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            if touch.type == .indirectPointer {
                continue // handle this in a different place
            }
            let locationInView = touch.location(in: rootView)
            let screenScale = UIScreen.main.scale
            currentHotbarSlot = enableHotbarGestures ?
                callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1
            if isTouchInactive(hotbarTouch) && currentHotbarSlot != -1 {
                hotbarTouch = touch
            }
            if isTouchInactive(primaryTouch) && currentHotbarSlot == -1 {
                primaryTouch = touch
            }
            sendTouchEvent(touch, withUIEvent: event, withEvent: ACTION_DOWN)
            break
        }
    }

    // Equals to Android ACTION_MOVE
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        for touch in touches {
            if touch.type == .indirectPointer {
                if isGrabbing == 0 && !virtualMouseEnabled {
                    let point = touch.location(in: rootView)
                    sendTouchPoint(point, withEvent: ACTION_MOVE)
                }
                continue // handle this in a different place
            }
            if hotbarTouch !== touch && isTouchInactive(primaryTouch) {
                // Replace the inactive touch with the current active touch
                primaryTouch = touch
                sendTouchEvent(touch, withUIEvent: event, withEvent: ACTION_DOWN)
            }
            sendTouchEvent(touch, withUIEvent: event, withEvent: ACTION_MOVE)
        }
    }

    // For ACTION_UP and ACTION_CANCEL
    func touchesEndedGlobal(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch.type == .indirectPointer {
                continue // handle this in a different place
            }
            sendTouchEvent(touch, withUIEvent: event, withEvent: ACTION_UP)
        }
    }

    // Equals to Android ACTION_UP
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touchesEndedGlobal(touches, with: event)
    }

    // Equals to Android ACTION_CANCEL
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchesEndedGlobal(touches, with: event)
    }

    // MARK: - LogView category

    func initCategory_LogView() {
        logOutputView = PLLogOutputView(frame: view.frame)
        logOutputView.navController?.additionalSafeAreaInsets = view.safeAreaInsets
        if let navController = logOutputView.navController {
            addChild(navController)
            rootView.addSubview(navController.view)
        }
    }

    // MARK: - ExternalDisplay category

    func switchToExternalDisplay() {
        surfaceView.removeFromSuperview()
        mousePointerView.removeFromSuperview()

        let noteLabel = UILabel(frame: view.frame)
        noteLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        noteLabel.numberOfLines = 0
        noteLabel.textAlignment = .center
        noteLabel.textColor = UIColor.white
        noteLabel.text = localize("game.note.airplay")
        touchView.addSubview(noteLabel)

        let secondWindow = UIWindow.externalWindow()
        secondWindow?.rootViewController = UIViewController()
        secondWindow?.rootViewController?.view.addSubview(surfaceView)
        secondWindow?.rootViewController?.view.addSubview(mousePointerView)

        secondWindow?.isHidden = false
        updateSavedResolution()
    }

    func switchToInternalDisplay() {
        surfaceView.removeFromSuperview()
        mousePointerView.removeFromSuperview()

        let secondWindow = UIWindow.externalWindow()
        secondWindow?.isHidden = true

        touchView.subviews[0].removeFromSuperview()
        touchView.addSubview(surfaceView)
        touchView.addSubview(mousePointerView)
        updateSavedResolution()
    }

    // MARK: - Navigation category

    func initCategory_Navigation() {
        let menuPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleRightEdge(_:)))
        menuPanGesture.delegate = self

        let menuSwipeLineView = UIView(frame: CGRect(x: 11.0, y: view.frame.size.height / 2 - 100.0, width: 8.0, height: 200.0))
        menuSwipeLineView.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin]
        menuSwipeLineView.backgroundColor = UIColor.white
        menuSwipeLineView.layer.cornerRadius = 4
        menuSwipeLineView.isUserInteractionEnabled = false

        let menuSwipeView = UIView(frame: CGRect(x: view.frame.size.width, y: 0, width: 30.0, height: view.frame.size.height))
        menuSwipeView.autoresizingMask = [.flexibleHeight, .flexibleLeftMargin]
        menuSwipeView.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.1)
        menuSwipeView.addGestureRecognizer(menuPanGesture)
        menuSwipeView.addSubview(menuSwipeLineView)
        rootView.addSubview(menuSwipeView)

        menuArray = ["game.menu.force_close", "game.menu.log_output", "game.menu.custom_controls", "Settings"]

        menuView = UITableView(frame: CGRect(x: view.frame.size.width + 30.0, y: 0,
                                             width: view.frame.size.width * 0.3 - 36.0 * 0.7, height: view.frame.size.height))

        //menuView.backgroundColor = UIColor(red: 240.0/255.0, green: 240.0/255.0, blue: 240.0/255.0, alpha: 1)
        menuView.dataSource = self
        menuView.delegate = self
        menuView.isHidden = true
        menuView.layer.cornerRadius = 12
        menuView.isScrollEnabled = false
        menuView.separatorInset = .zero
        view.addSubview(menuView)
    }

    func setupCategory_Navigation() {
        edgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleRightEdge(_:)))
        edgeGesture.edges = .right
        edgeGesture.delegate = self
        touchView.addGestureRecognizer(edgeGesture)
    }

    func animateMenuScale(_ scale: CGFloat, duration: CGFloat) {
        let centerX = rootView.bounds.size.width / 2
        let centerY = rootView.bounds.size.height / 2
        UIView.animate(withDuration: TimeInterval(duration), delay: 0, options: .curveEaseOut, animations: {
            lastCenterPoint.x = centerX * scale
            self.rootView.center = CGPoint(x: lastCenterPoint.x, y: centerY)
            self.rootView.transform = CGAffineTransform.identity.scaledBy(x: scale, y: scale)
            self.menuView.transform = CGAffineTransform.identity.scaledBy(x: (1.1 - scale) * 2.5, y: (1.1 - scale) * 2.5)
            self.menuView.frame = CGRect(x: self.rootView.frame.size.width, y: self.rootView.frame.origin.y,
                                         width: self.menuView.frame.size.width, height: self.menuView.contentSize.height)
        }, completion: { _ in
            self.menuView.isHidden = scale == 1.0
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            self.setNeedsStatusBarAppearanceUpdate()
        })
    }

    func handleRightEdge(_ sender: UIPanGestureRecognizer) {
        if lastCenterPoint.y == 0 {
            lastCenterPoint.x = rootView.center.x
            lastCenterPoint.y = 1
        }

        let centerX = rootView.bounds.size.width / 2
        let centerY = rootView.bounds.size.height / 2

        let translation = sender.translation(in: sender.view)

        if sender.state == .began {
            menuView.isHidden = false
        } else if sender.state == .changed {
            rootView.center = CGPoint(x: lastCenterPoint.x + translation.x / 2, y: centerY + translation.y / 10.0)
            let scale = max(0.7, rootView.center.x / centerX)
            rootView.transform = CGAffineTransform.identity.scaledBy(x: scale, y: scale)

            menuView.frame = CGRect(x: rootView.frame.size.width, y: rootView.frame.origin.y,
                                    width: menuView.frame.size.width, height: menuView.contentSize.height)
            // scale is in range of 0.7-1
            // 1.1 - scale produces in range of 0.4-0.1
            // result in transform scale range of 1-0.25
            menuView.transform = CGAffineTransform.identity.scaledBy(x: (1.1 - scale) * 2.5, y: (1.1 - scale) * 2.5)
        } else {
            let velocity = sender.velocity(in: sender.view)
            let scale: CGFloat = (velocity.x >= 0) ? 1 : 0.7

            // calculate duration to produce smooth movement
            // FIXME: any better way?
            var duration = abs(rootView.center.x - centerX * scale) / centerX + 0.1
            duration = min(0.4, duration)
            //(110 - MIN(100, fabs(velocity.x))) / 100

            animateMenuScale(scale, duration: duration)
        }
    }

    func actionForceClose() {
        let alert = UIAlertController(title: nil,
                                      message: localize("game.menu.confirm.force_close"),
                                      preferredStyle: .alert)

        let cancelAction = UIAlertAction(title: localize("Cancel"), style: .default, handler: nil)
        alert.addAction(cancelAction)

        let okAction = UIAlertAction(title: localize("OK"), style: .destructive) { _ in
            UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseIn, animations: {
                self.rootView.center = CGPoint(x: self.rootView.bounds.size.width / -2, y: self.rootView.center.y)
                self.menuView.frame = CGRect(x: self.view.frame.size.width, y: 0, width: 0, height: 0)
            }, completion: { _ in
                if fatalExitGroup == nil {
                    exit(0)
                } else {
                    fatalExitGroup.leave()
                }
            })
        }
        alert.addAction(okAction)

        present(alert, animated: true, completion: nil)
    }

    func actionOpenCustomControls() {
        animateMenuScale(1, duration: 0.5)
        ctrlView.removeAllButtons()
        let vc = CustomControlsViewController()
        vc.modalPresentationStyle = .overFullScreen
        vc.setDefaultCtrl = { name in
            let profile: NSMutableDictionary? = PLProfiles.current().selectedProfile()
            if profile?.object(forKey: "defaultTouchCtrl") != nil {
                // Save default to current profile
                profile?.setObject(name, forKey: "defaultTouchCtrl" as NSString)
            } else {
                // Save default to preferences
                setPrefObject("control.default_ctrl", name)
            }
        }
        vc.getDefaultCtrl = {
            return (PLProfiles.resolveKeyForCurrentProfile("defaultTouchCtrl") as? String) ?? ""
        }
        present(vc, animated: false, completion: nil)
    }

    func actionOpenPreferences() {
        let vc = LauncherPreferencesViewController()
        present(vc, animated: true, completion: nil)
    }

    func actionOpenNavigationMenu() {
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        if !menuView.isHidden {
            return []
        }
        return [.bottom, .right]
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return menuView.isHidden &&
            getPrefBool("debug.debug_hide_home_indicator")
    }

    override var prefersStatusBarHidden: Bool {
        return menuView.isHidden
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return menuArray.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var cell = tableView.dequeueReusableCell(withIdentifier: "cell")

        if cell == nil {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        }
        cell?.backgroundColor = UIColor.systemFill

        cell?.textLabel?.text = localize(menuArray[indexPath.row])

        return cell!
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        didSelectMenuItem(Int32(indexPath.row))
    }

    func didSelectMenuItem(_ item: Int32) {
        switch item {
        case 0:
            actionForceClose()
        case 1:
            logOutputView.actionToggleLogOutput()
        case 2:
            actionOpenCustomControls()
        case 3:
            actionOpenPreferences()
        default:
            break
        }
    }

    func viewWillTransitionToSize_Navigation(_ frame: CGRect) {
        if rootView.transform.a != 0 {
            let centerX = rootView.bounds.size.width / 2
            let centerY = rootView.bounds.size.height / 2
            lastCenterPoint = CGPoint(x: centerX * rootView.transform.a, y: centerY)
            rootView.center = lastCenterPoint
        }

        menuView.frame = CGRect(x: rootView.frame.size.width, y: rootView.frame.origin.y,
                                width: frame.size.width * 0.3 - 30.0 * 0.7, height: menuView.contentSize.height)
    }
}
