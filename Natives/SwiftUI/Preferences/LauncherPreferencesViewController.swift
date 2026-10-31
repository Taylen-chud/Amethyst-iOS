import UIKit

@objc(LauncherPreferencesViewController)
@objcMembers
class LauncherPreferencesViewController: PLPrefTableViewController {

    private var rendererKeys: [String] = []
    private var rendererList: [String] = []

    override init() {
        super.init()
        title = localize("Settings")
    }

    override init(style: UITableView.Style) {
        super.init(style: style)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Asked by the launcher menu by selector
    func imageName() -> String {
        return "MenuSettings"
    }

    override func viewDidLoad() {
        getPreference = { section, key in
            return getPrefObject("\(section).\(key)")
        }
        setPreference = { section, key, value in
            setPrefObject("\(section).\(key)", value)
        }

        hasDetail = true
        prefDetailVisible = navigationController == nil

        prefSections = ["general", "video", "control", "java", "debug"]

        rendererKeys = (getRendererKeys(false) as? [String]) ?? []
        rendererList = (getRendererNames(false) as? [String]) ?? []

        let whenNotInGame: () -> Bool = { [weak self] in
            return self?.navigationController != nil
        }
        let totalMemoryMB = ProcessInfo.processInfo.physicalMemory / 1048576
        let notTV: () -> Bool = {
            return realUIIdiom != .tv
        }

        prefContents = [
            [
                // General settings
                PrefItem(icon: "cube"),
                PrefItem(kind: .button, key: "curseforge_api_key", icon: "key",
                         enableCondition: whenNotInGame,
                         action: { [weak self] in self?.editCurseForgeKey() }),
                PrefItem(kind: .toggle, key: "check_sha", icon: "lock.shield", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "cosmetica", icon: "eyeglasses", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "debug_logging", icon: "doc.badge.gearshape", hasDetail: true,
                         onToggle: { enabled in
                             debugLogEnabled = enabled
                             NSLog("[Debugging] Debug log enabled: %@", enabled ? "YES" : "NO")
                         }),
                PrefItem(kind: .pickField, key: "appicon", icon: "paintbrush", hasDetail: true,
                         enableCondition: { UIApplication.shared.supportsAlternateIcons },
                         pickKeys: ["AppIcon-Light"],
                         pickList: [localize("preference.title.appicon-default")],
                         onPick: { pickedName in
                             var iconName: String? = pickedName
                             if iconName == "AppIcon-Light" {
                                 iconName = nil
                             }
                             UIApplication.shared.setAlternateIconName(iconName) { error in
                                 guard let error = error else { return }
                                 NSLog("Error in appicon: %@", "\(error)")
                                 showDialog(localize("Error"), error.localizedDescription)
                             }
                         }),
                PrefItem(kind: .toggle, key: "hidden_sidebar", icon: "sidebar.leading", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .button, key: "reset_warnings", icon: "exclamationmark.triangle",
                         enableCondition: whenNotInGame,
                         action: { resetWarnings() }),
                PrefItem(kind: .button, key: "reset_settings", icon: "trash",
                         destructive: true, requestReload: true, showConfirmPrompt: true,
                         enableCondition: whenNotInGame,
                         action: { [weak self] in
                             loadPreferences(true)
                             self?.tableView.reloadData()
                         }),
                PrefItem(kind: .button, key: "erase_demo_data", icon: "trash",
                         destructive: true, showConfirmPrompt: true,
                         enableCondition: {
                             let demoPath = "\(envString("AME_HOME") ?? "")/.demo"
                             let count = ((try? FileManager.default.contentsOfDirectory(atPath: demoPath)) ?? []).count
                             return whenNotInGame() && count > 0
                         },
                         action: { [weak self] in
                             let demoPath = "\(envString("AME_HOME") ?? "")/.demo"
                             do {
                                 try FileManager.default.removeItem(atPath: demoPath)
                                 try? FileManager.default.createDirectory(atPath: demoPath, withIntermediateDirectories: true, attributes: nil)
                                 _ = FileManager.default.changeCurrentDirectoryPath(demoPath)
                                 if getenv("DEMO_LOCK") != nil {
                                     (self?.navigationController as? LauncherNavigationController)?.fetchLocalVersionList()
                                 }
                             } catch {
                                 NSLog("Error in erase_demo_data: %@", "\(error)")
                                 showDialog(localize("Error"), error.localizedDescription)
                             }
                         }),
            ], [
                // Video and renderer settings
                PrefItem(icon: "video"),
                PrefItem(kind: .pickField, key: "renderer", icon: "cpu", hasDetail: true,
                         enableCondition: whenNotInGame,
                         pickKeys: rendererKeys, pickList: rendererList),
                PrefItem(kind: .slider, key: "resolution", icon: "viewfinder", hasDetail: true,
                         min: 25, max: 150),
                PrefItem(kind: .toggle, key: "max_framerate", icon: "timelapse", hasDetail: true,
                         enableCondition: { whenNotInGame() && (UIScreen.main.maximumFramesPerSecond > 60) }),
                PrefItem(kind: .toggle, key: "performance_hud", icon: "waveform.path.ecg", hasDetail: true,
                         enableCondition: { CAMetalLayer.instancesRespond(to: NSSelectorFromString("developerHUDProperties")) }),
                PrefItem(kind: .toggle, key: "mobilegl_fast_shader_load", icon: "hare", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "mobilegl_buffer_compat", icon: "square.stack.3d.up", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "mobilegl_relaxed", icon: "slider.horizontal.3", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "moltenvk_fast_math", icon: "bolt", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "moltenvk_argument_buffers", icon: "square.grid.3x3", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "moltenvk_smooth_scaling", icon: "arrow.up.left.and.arrow.down.right", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "fullscreen_airplay", icon: "airplayvideo", hasDetail: true,
                         onToggle: { [weak self] enabled in
                             guard let self = self else { return }
                             if self.navigationController != nil { return }
                             if UIApplication.shared.connectedScenes.count < 2 { return }
                             let surfaceVC = self.presentingViewController as? SurfaceViewController
                             if enabled {
                                 surfaceVC?.switchToExternalDisplay()
                             } else {
                                 surfaceVC?.switchToInternalDisplay()
                             }
                         }),
                PrefItem(kind: .toggle, key: "silence_other_audio", icon: "speaker.slash", hasDetail: true),
                PrefItem(kind: .toggle, key: "silence_with_switch", icon: "speaker.zzz", hasDetail: true),
                PrefItem(kind: .toggle, key: "allow_microphone", icon: "mic", hasDetail: true),
            ], [
                // Control settings
                PrefItem(icon: "gamecontroller"),
                PrefItem(kind: .childPane, key: "default_gamepad_ctrl", icon: "hammer",
                         enableCondition: whenNotInGame,
                         canDismissWithSwipe: false,
                         makeChild: { LauncherPrefContCfgViewController() }),
                PrefItem(kind: .toggle, key: "hardware_hide", icon: "eye.slash", hasDetail: true),
                PrefItem(kind: .toggle, key: "recording_hide", icon: "eye.slash", hasDetail: true),
                PrefItem(kind: .toggle, key: "gesture_mouse", icon: "cursorarrow.click", hasDetail: true),
                PrefItem(kind: .toggle, key: "gesture_hotbar", icon: "hand.tap", hasDetail: true),
                PrefItem(kind: .toggle, key: "disable_haptics", icon: "wave.3.left", hasDetail: false),
                PrefItem(kind: .toggle, key: "slideable_hotbar", icon: "slider.horizontal.below.rectangle", hasDetail: true),
                PrefItem(kind: .slider, key: "press_duration", icon: "cursorarrow.click.badge.clock", hasDetail: true,
                         min: 100, max: 1000),
                PrefItem(kind: .slider, key: "button_scale", icon: "aspectratio", hasDetail: true,
                         min: 50, max: 500), // 80?
                PrefItem(kind: .slider, key: "mouse_scale", icon: "arrow.up.left.and.arrow.down.right.circle", hasDetail: true,
                         min: 25, max: 300),
                PrefItem(kind: .slider, key: "mouse_speed", icon: "cursorarrow.motionlines", hasDetail: true,
                         min: 25, max: 300),
                PrefItem(kind: .toggle, key: "virtmouse_enable", icon: "cursorarrow.rays", hasDetail: true),
                PrefItem(kind: .toggle, key: "gyroscope_enable", icon: "gyroscope", hasDetail: true,
                         enableCondition: notTV),
                PrefItem(kind: .toggle, key: "gyroscope_invert_x_axis", icon: "arrow.left.and.right", hasDetail: true,
                         enableCondition: notTV),
                PrefItem(kind: .slider, key: "gyroscope_sensitivity", icon: "move.3d", hasDetail: true,
                         enableCondition: notTV,
                         min: 50, max: 300),
            ], [
                // Java tweaks
                PrefItem(icon: "sparkles"),
                PrefItem(kind: .childPane, key: "manage_runtime", icon: "cube", hasDetail: true,
                         enableCondition: whenNotInGame,
                         canDismissWithSwipe: true,
                         makeChild: { LauncherPrefManageJREViewController() }),
                PrefItem(kind: .textField, key: "java_args", icon: "slider.vertical.3", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .textField, key: "env_variables", icon: "terminal", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "auto_ram", icon: "slider.horizontal.3", hasDetail: true,
                         requestReload: true,
                         enableCondition: whenNotInGame,
                         warnCondition: { _ in !isJailbroken },
                         warnKey: "auto_ram_warn"),
                PrefItem(kind: .slider, key: "allocated_memory", icon: "memorychip", hasDetail: true,
                         enableCondition: { !getPrefBool("java.auto_ram") && whenNotInGame() },
                         min: 250,
                         max: Int(Double(totalMemoryMB) * 0.85),
                         warnCondition: { view in
                             guard let slider = view as? UISlider else { return false }
                             return Double(slider.value) >= Double(totalMemoryMB) * 0.37
                         },
                         warnKey: "mem_warn"),
            ], [
                // Debug settings - only recommended for developer use
                PrefItem(icon: "ladybug"),
                PrefItem(kind: .toggle, key: "debug_always_attached_jit", icon: "app.connected.to.app.below.fill", hasDetail: true,
                         enableCondition: {
                             // DeviceHasJITFlags(a | b) is true only when both flags are set
                             return DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED) && DeviceHasJITFlags(JIT_FLAG_HAS_TXM) && whenNotInGame()
                         }),
                PrefItem(kind: .toggle, key: "debug_skip_wait_jit", icon: "forward", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "debug_hide_home_indicator", icon: "iphone.and.arrow.forward", hasDetail: true,
                         enableCondition: { [weak self] in
                             guard let self = self else { return false }
                             return (self.splitViewController?.view.safeAreaInsets.bottom ?? 0) > 0 ||
                                 self.view.safeAreaInsets.bottom > 0
                         }),
                PrefItem(kind: .toggle, key: "debug_ipad_ui", icon: "ipad", hasDetail: true,
                         enableCondition: whenNotInGame),
                PrefItem(kind: .toggle, key: "debug_auto_correction", icon: "textformat.abc.dottedunderline", hasDetail: true),
            ]
        ]

        super.viewDidLoad()
        if navigationController == nil {
            tableView.alpha = 0.9
        }
        if ProcessInfo.processInfo.isMacCatalystApp {
            let closeButton = UIButton(type: .close)
            closeButton.frame = closeButton.frame.offsetBy(dx: 10, dy: 10)
            closeButton.addTarget(self, action: #selector(actionClose), for: .touchUpInside)
            view.addSubview(closeButton)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if navigationController == nil {
            // SurfaceViewController applies the changed preferences when this page goes away
            let selector = NSSelectorFromString("updatePreferenceChanges")
            if let presenting = presentingViewController, presenting.responds(to: selector) {
                presenting.perform(selector)
            }
        }
    }

    func actionClose() {
        dismiss(animated: true)
    }

    // MARK: UITableView

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { // Add to general section
            let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "(null)"
            let osVersion = UIDevice.current.completeOSVersion() ?? ""
            let installType = envString("AME_DETECTEDINST") ?? "(null)"
            return "Angel Aura Amethyst \(version)-\(CONFIG_TYPE) (\(CONFIG_BRANCH)/\(CONFIG_COMMIT))\n\(osVersion) on \(hostModelName()) (\(installType))\nPID: \(getpid())"
        }

        guard let sectionName = prefSections?[section] else { return nil }
        let footer = NSLocalizedString("preference.section.footer.\(sectionName)", tableName: "Localizable", bundle: Bundle.main, value: " ", comment: "")
        if footer == " " {
            return nil
        }
        return footer
    }

    func editCurseForgeKey() {
        let alert = UIAlertController(title: localize("preference.title.curseforge_api_key"),
                                      message: localize("preference.description.curseforge_api_key"),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.textContentType = UITextContentType(rawValue: "")
            field.placeholder = CurseForgeAPI.isConfigured() ? localize("content.curseforge.key_present") : localize("content.curseforge.key_placeholder")
        }
        alert.addAction(UIAlertAction(title: localize("Cancel"), style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: localize("Save"), style: .default) { [weak alert] _ in
            guard let key = alert?.textFields?.first?.text, !key.isEmpty else { return }
            do {
                try CurseForgeAPI.setAPIKey(key)
            } catch {
                showDialog(localize("Error"), error.localizedDescription)
            }
        })
        if CurseForgeAPI.isConfigured() {
            alert.addAction(UIAlertAction(title: localize("content.curseforge.remove_key"), style: .destructive) { _ in
                do {
                    try CurseForgeAPI.setAPIKey("")
                } catch {
                    showDialog(localize("Error"), error.localizedDescription)
                }
            })
        }
        present(alert, animated: true)
    }
}
