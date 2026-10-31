import UIKit

// The "Edit" panel for a single control button. Port of CCMenuViewController from CustomControlsViewController.m.

private let TAG_SLIDER_STROKEWIDTH = 10

private let VISIBILITY_ALWAYS = 0
private let VISIBILITY_IN_GAME = 1
private let VISIBILITY_IN_MENU = 2

@objc(CCMenuViewController)
class CCMenuViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
    var targetButton: ControlButton?

    private var keyCodeMap = NSMutableArray()
    private var keyValueMap = NSMutableArray()
    private var arrOrientation: [String] = []
    private var arrVisibility: [String] = []
    private var oldProperties: NSMutableDictionary?

    private var scrollView: UIScrollView!
    private var editName: UITextField?
    private var editSizeWidth: UITextField?
    private var editSizeHeight: UITextField?
    private var editMapping: UITextView?
    private var pickerMapping: UIPickerView?
    private var ctrlOrientation: UISegmentedControl?
    private var ctrlVisibility: UISegmentedControl?
    private var switchFwdLock: UISwitch?
    private var switchToggleable: UISwitch?
    private var switchMousePass: UISwitch?
    private var switchSwipeable: UISwitch?
    private var colorWellBackground: UIColorWell?
    private var colorWellStroke: UIColorWell?
    private var sliderStrokeWidth: DBNumberedSlider?
    private var sliderCornerRadius: DBNumberedSlider?
    private var sliderOpacity: DBNumberedSlider?

    private var currentY: CGFloat = 0
    private var dragLastPoint: CGPoint = .zero

    private func number(_ key: String) -> NSNumber? {
        return targetButton?.prop(key) as? NSNumber
    }

    private func addLabel(_ name: String) -> UILabel {
        let label = UILabel(frame: CGRect(x: 0.0, y: currentY, width: 0.0, height: 0.0))
        label.text = name
        label.numberOfLines = 0
        label.sizeToFit()
        scrollView.addSubview(label)
        return label
    }

    private func isFreeOrientationOrNotSubButton() -> Bool {
        guard let sub = targetButton as? ControlSubButton else { return true }
        return (sub.parentDrawer?.drawerData?.object(forKey: "orientation") as? String) == "FREE"
    }

    private func makeTextField(frame: CGRect, placeholder: String, decimal: Bool, text: String?) -> UITextField {
        let field = UITextField(frame: frame)
        field.addTarget(self, action: #selector(textFieldEditingChanged), for: .editingChanged)
        field.addTarget(field, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
        if decimal {
            field.keyboardType = .decimalPad
        }
        field.placeholder = placeholder
        field.returnKeyType = .done
        field.text = text
        return field
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        keyCodeMap = NSMutableArray()
        keyValueMap = NSMutableArray()
        initKeycodeTable(keyCodeMap, keyValueMap)

        oldProperties = targetButton?.properties?.mutableCopy() as? NSMutableDictionary
        currentY = 6.0

        let shortest = min(view.frame.size.width, view.frame.size.height)
        let tempW = min(view.frame.size.width * 0.75, shortest)
        let tempH = min(view.frame.size.height * 0.6, shortest)

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blurView.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin, .flexibleRightMargin, .flexibleBottomMargin]
        blurView.frame = CGRect(
            x: (view.frame.size.width - max(tempW, tempH)) / 2,
            y: (view.frame.size.height - min(tempW, tempH)) / 2,
            width: max(tempW, tempH), height: min(tempW, tempH))
        blurView.layer.cornerRadius = 10.0
        blurView.clipsToBounds = true
        view.addSubview(blurView)

        let btnFlexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: self, action: nil)

        let popoverToolbar = UIToolbar(frame: CGRect(x: 0.0, y: 0.0, width: blurView.frame.size.width, height: 44.0))
        let dragVCGesture = UIPanGestureRecognizer(target: self, action: #selector(dragViewController(_:)))
        dragVCGesture.minimumNumberOfTouches = 1
        dragVCGesture.maximumNumberOfTouches = 1
        popoverToolbar.addGestureRecognizer(dragVCGesture)

        let popoverCancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(actionEditCancel))
        let popoverDoneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(actionEditFinish))
        popoverToolbar.items = [popoverCancelButton, btnFlexibleSpace, popoverDoneButton]
        blurView.contentView.addSubview(popoverToolbar)

        scrollView = UIScrollView(frame: CGRect(x: 5.0, y: popoverToolbar.frame.size.height,
                                                width: blurView.frame.size.width - 10.0,
                                                height: blurView.frame.size.height - popoverToolbar.frame.size.height))
        scrollView.keyboardDismissMode = .interactive
        blurView.contentView.addSubview(scrollView)

        let editPickToolbar = UIToolbar(frame: CGRect(x: 0.0, y: 0.0, width: blurView.frame.size.width, height: 44.0))
        let editDoneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closeTextField))
        editPickToolbar.items = [btnFlexibleSpace, editDoneButton]

        let width = blurView.frame.size.width - 10.0

        // Property: Name
        if !(targetButton is ControlJoystick) {
            let labelName = addLabel(localize("custom_controls.button_edit.name"))
            let field = makeTextField(
                frame: CGRect(x: labelName.frame.size.width + 5.0, y: currentY,
                              width: width - labelName.frame.size.width - 5.0, height: labelName.frame.size.height),
                placeholder: localize("custom_controls.button_edit.name"), decimal: false,
                text: targetButton?.prop("name") as? String)
            editName = field
            scrollView.addSubview(field)
            currentY += labelName.frame.size.height + 15.0
        }

        if isFreeOrientationOrNotSubButton() {
            // Property: Size
            let labelSize = addLabel(localize("custom_controls.button_edit.size"))
            let editSizeWidthValue = (width - labelSize.frame.size.width) / 2 - labelSize.frame.size.height / 2
            let labelSizeX = UILabel(frame: CGRect(x: labelSize.frame.size.width + editSizeWidthValue, y: labelSize.frame.origin.y,
                                                   width: labelSize.frame.size.height, height: labelSize.frame.size.height))
            labelSizeX.text = "x"
            scrollView.addSubview(labelSizeX)
            let widthField = makeTextField(
                frame: CGRect(x: labelSize.frame.size.width, y: labelSize.frame.origin.y,
                              width: editSizeWidthValue, height: labelSize.frame.size.height),
                placeholder: "width", decimal: true, text: number("width")?.stringValue)
            widthField.textAlignment = .center
            editSizeWidth = widthField
            scrollView.addSubview(widthField)
            let heightField = makeTextField(
                frame: CGRect(x: labelSizeX.frame.origin.x + labelSizeX.frame.size.width, y: labelSize.frame.origin.y,
                              width: editSizeWidthValue, height: labelSize.frame.size.height),
                placeholder: "height", decimal: true, text: number("height")?.stringValue)
            heightField.textAlignment = .center
            editSizeHeight = heightField
            scrollView.addSubview(heightField)
            currentY += labelSize.frame.size.height + 15.0
        }

        if let drawer = targetButton as? ControlDrawer {
            // Property: Orientation
            arrOrientation = ["DOWN", "LEFT", "UP", "RIGHT", "FREE"]
            let labelOrientation = addLabel(localize("custom_controls.button_edit.orientation"))
            let control = UISegmentedControl(items: arrOrientation)
            control.addTarget(self, action: #selector(orientationValueChanged(_:)), for: .valueChanged)
            control.frame = CGRect(x: labelOrientation.frame.size.width + 5.0, y: currentY - 5.0,
                                   width: width - labelOrientation.frame.size.width - 5.0, height: 30.0)
            if let orientation = drawer.drawerData?.object(forKey: "orientation") as? String,
               let index = arrOrientation.firstIndex(of: orientation) {
                control.selectedSegmentIndex = index
            }
            ctrlOrientation = control
            scrollView.addSubview(control)
            currentY += labelOrientation.frame.size.height + 15.0
        } else if targetButton is ControlJoystick {
            // Property: Forward lock
            let labelFwdLock = addLabel(localize("custom_controls.button_edit.forward_lock"))
            let toggle = UISwitch(frame: CGRect(x: width - 62.0, y: currentY - 5.0, width: 50.0, height: 30))
            toggle.setOn(number("forwardLock")?.boolValue ?? false, animated: false)
            switchFwdLock = toggle
            scrollView.addSubview(toggle)
            currentY += labelFwdLock.frame.size.height + 15.0
        } else {
            // Property: Mapping
            let labelMapping = addLabel(localize("custom_controls.button_edit.mapping"))

            let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            textView.text = "\n\n\n"
            textView.sizeToFit()
            textView.isScrollEnabled = false
            textView.frame = CGRect(x: labelMapping.frame.size.width + 5.0, y: labelMapping.frame.origin.y,
                                    width: width - labelMapping.frame.size.width - 5.0, height: textView.frame.size.height)
            editMapping = textView

            let picker = UIPickerView()
            picker.delegate = self
            picker.dataSource = self
            picker.reloadAllComponents()
            let keycodes = targetButton?.prop("keycodes") as? NSArray
            for i in 0..<4 {
                if let keycodes = keycodes, i < keycodes.count {
                    let row = keyValueMap.index(of: keycodes[i])
                    if row != NSNotFound {
                        picker.selectRow(row, inComponent: i, animated: false)
                    }
                }
            }
            pickerMapping = picker
            pickerView(picker, didSelectRow: 0, inComponent: 0)

            textView.inputAccessoryView = editPickToolbar
            textView.inputView = picker
            scrollView.addSubview(textView)
            currentY += textView.frame.size.height + 15.0
        }

        if !(targetButton is ControlJoystick) {
            // Property: Toggleable
            let labelToggleable = addLabel(localize("custom_controls.button_edit.toggleable"))
            let toggleable = UISwitch(frame: CGRect(x: width - 62.0, y: currentY - 5.0, width: 50.0, height: 30))
            toggleable.setOn(number("isToggle")?.boolValue ?? false, animated: false)
            switchToggleable = toggleable
            scrollView.addSubview(toggleable)
            currentY += labelToggleable.frame.size.height + 15.0

            // Property: Mouse pass
            let labelMousePass = addLabel(localize("custom_controls.button_edit.mouse_pass"))
            let mousePass = UISwitch(frame: CGRect(x: width - 62.0, y: currentY - 5.0, width: 50.0, height: 30))
            mousePass.isOn = number("passThruEnabled")?.boolValue ?? false
            switchMousePass = mousePass
            scrollView.addSubview(mousePass)
            currentY += labelMousePass.frame.size.height + 15.0

            // Property: Swipeable
            let labelSwipeable = addLabel(localize("custom_controls.button_edit.swipeable"))
            let swipeable = UISwitch(frame: CGRect(x: width - 62.0, y: currentY - 5.0, width: 50.0, height: 30))
            swipeable.isOn = number("isSwipeable")?.boolValue ?? false
            switchSwipeable = swipeable
            scrollView.addSubview(swipeable)
            currentY += labelSwipeable.frame.size.height + 15.0
        }

        // Property: Background color
        let labelBGColor = addLabel(localize("custom_controls.button_edit.bg_color"))
        let bgWell = UIColorWell(frame: CGRect(x: width - 42.0, y: currentY - 5.0, width: 30.0, height: 30.0))
        bgWell.addTarget(self, action: #selector(colorWellChanged), for: .valueChanged)
        bgWell.selectedColor = convertARGB2UIColor(number("bgColor")?.int32Value ?? 0)
        colorWellBackground = bgWell
        scrollView.addSubview(bgWell)
        currentY += labelBGColor.frame.size.height + 15.0

        // Property: Stroke width
        let labelStrokeWidth = addLabel(localize("custom_controls.button_edit.stroke_width"))
        let strokeSlider = DBNumberedSlider(frame: CGRect(x: labelStrokeWidth.frame.size.width + 5.0, y: currentY - 5.0,
                                                          width: width - labelStrokeWidth.frame.size.width - 5.0, height: 30.0))
        strokeSlider.isContinuous = true
        strokeSlider.maximumValue = Float(max(number("width")?.intValue ?? 0, number("height")?.intValue ?? 0) / 2)
        strokeSlider.tag = TAG_SLIDER_STROKEWIDTH
        strokeSlider.value = Float(number("strokeWidth")?.intValue ?? 0)
        strokeSlider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
        sliderStrokeWidth = strokeSlider
        scrollView.addSubview(strokeSlider)
        currentY += labelStrokeWidth.frame.size.height + 15.0

        // Property: Stroke color
        let labelStrokeColor = addLabel(localize("custom_controls.button_edit.stroke_color"))
        let strokeWell = UIColorWell(frame: CGRect(x: width - 42.0, y: currentY - 5.0, width: 30.0, height: 30.0))
        strokeWell.addTarget(self, action: #selector(colorWellChanged), for: .valueChanged)
        strokeWell.selectedColor = convertARGB2UIColor(number("strokeColor")?.int32Value ?? 0)
        colorWellStroke = strokeWell
        scrollView.addSubview(strokeWell)
        currentY += labelStrokeColor.frame.size.height + 15.0

        // Property: Corner radius
        if !(targetButton is ControlJoystick) {
            let labelCornerRadius = addLabel(localize("custom_controls.button_edit.corner_radius"))
            let radiusSlider = DBNumberedSlider(frame: CGRect(x: labelCornerRadius.frame.size.width + 5.0, y: currentY - 5.0,
                                                              width: width - labelCornerRadius.frame.size.width - 5.0, height: 30.0))
            radiusSlider.isContinuous = true
            radiusSlider.maximumValue = 100
            radiusSlider.value = Float(number("cornerRadius")?.intValue ?? 0)
            radiusSlider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
            sliderCornerRadius = radiusSlider
            scrollView.addSubview(radiusSlider)
            currentY += labelCornerRadius.frame.size.height + 15.0
        }

        // Property: Button Opacity
        let labelOpacity = addLabel(localize("custom_controls.button_edit.opacity"))
        let opacitySlider = DBNumberedSlider(frame: CGRect(x: labelOpacity.frame.size.width + 5.0, y: currentY - 5.0,
                                                           width: width - labelOpacity.frame.size.width - 5.0, height: 30.0))
        opacitySlider.isContinuous = true
        opacitySlider.minimumValue = 1
        opacitySlider.maximumValue = 100
        opacitySlider.value = (number("opacity")?.floatValue ?? 0) * 100.0
        opacitySlider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
        sliderOpacity = opacitySlider
        scrollView.addSubview(opacitySlider)
        currentY += labelOpacity.frame.size.height + 15.0

        // Property: Visibility
        arrVisibility = [localize("Always"), localize("In game"), localize("In menu")]
        let labelVisibility = addLabel(localize("custom_controls.button_edit.visibility"))
        let visibility = UISegmentedControl(items: arrVisibility)
        visibility.addTarget(self, action: #selector(visibilityValueChanged(_:)), for: .valueChanged)
        visibility.frame = CGRect(x: labelVisibility.frame.size.width + 5.0, y: currentY - 5.0,
                                  width: width - labelVisibility.frame.size.width - 5.0, height: 30.0)
        let displayInGame = number("displayInGame")?.boolValue ?? false
        let displayInMenu = number("displayInMenu")?.boolValue ?? false
        if displayInGame && displayInMenu {
            visibility.selectedSegmentIndex = VISIBILITY_ALWAYS
        } else if displayInGame {
            visibility.selectedSegmentIndex = VISIBILITY_IN_GAME
        } else if displayInMenu {
            visibility.selectedSegmentIndex = VISIBILITY_IN_MENU
        } // else the segment is not chosen
        ctrlVisibility = visibility
        scrollView.addSubview(visibility)
        currentY += labelVisibility.frame.size.height + 15.0

        scrollView.contentSize = CGSize(width: scrollView.contentSize.width, height: currentY)
    }

    // MARK: - Gesture callback

    @objc func dragViewController(_ sender: UIPanGestureRecognizer) {
        let point = sender.translation(in: view)
        if sender.state != .began, let panel = view.subviews.first {
            var rect = panel.frame
            rect.origin.x = clamp(rect.origin.x - dragLastPoint.x + point.x,
                                  -view.frame.size.width / 2,
                                  view.frame.size.width - (sender.view?.frame.size.width ?? 0) / 2)
            rect.origin.y = clamp(rect.origin.y - dragLastPoint.y + point.y,
                                  0,
                                  view.frame.size.height - (sender.view?.frame.size.height ?? 0))
            panel.frame = rect
        }
        dragLastPoint = point
    }

    // MARK: - Color picker functions

    @objc func colorWellChanged() {
        if let color = colorWellBackground?.selectedColor {
            targetButton?.setProp("bgColor", NSNumber(value: convertUIColor2ARGB(color)))
        }
        if let color = colorWellStroke?.selectedColor {
            targetButton?.setProp("strokeColor", NSNumber(value: convertUIColor2ARGB(color)))
        }
        targetButton?.update()
    }

    @objc func textFieldEditingChanged() {
        targetButton?.setProp("name", editName?.text)
        targetButton?.setProp("width", NSNumber(value: Float(editSizeWidth?.text ?? "") ?? 0))
        targetButton?.setProp("height", NSNumber(value: Float(editSizeHeight?.text ?? "") ?? 0))
        targetButton?.update()
    }

    // MARK: - Control editor

    @objc func actionEditCancel() {
        targetButton?.properties = oldProperties
        targetButton?.update()
        dismiss(animated: true, completion: nil)
    }

    @objc func actionEditFinish() {
        if let fwdLock = switchFwdLock {
            targetButton?.setProp("forwardLock", NSNumber(value: fwdLock.isOn))
        }
        targetButton?.setProp("isToggle", NSNumber(value: switchToggleable?.isOn ?? false))
        targetButton?.setProp("passThruEnabled", NSNumber(value: switchMousePass?.isOn ?? false))
        targetButton?.setProp("isSwipeable", NSNumber(value: switchSwipeable?.isOn ?? false))

        if let button = targetButton,
           let old = oldProperties,
           let newProperties = button.properties?.mutableCopy() as? NSMutableDictionary {
            for case let key as NSCopying in old.allKeys {
                let oldValue = old.object(forKey: key)
                let newValue = newProperties.object(forKey: key)
                if let oldValue = oldValue, (oldValue as AnyObject).isEqual(newValue) {
                    newProperties.removeObject(forKey: key)
                }
            }

            (presentingViewController as? CustomControlsViewController)?
                .doUpdateButton(button, from: old, to: newProperties)
        }
        oldProperties = nil
        dismiss(animated: true, completion: nil)
    }

    @objc func orientationValueChanged(_ sender: UISegmentedControl) {
        guard let drawer = targetButton as? ControlDrawer,
              sender.selectedSegmentIndex >= 0, sender.selectedSegmentIndex < arrOrientation.count else { return }
        drawer.drawerData?.setObject(arrOrientation[sender.selectedSegmentIndex], forKey: "orientation" as NSString)
        drawer.syncButtons()
    }

    @objc func sliderValueChanged(_ sender: DBNumberedSlider) {
        if sender.tag == TAG_SLIDER_STROKEWIDTH {
            colorWellStroke?.isEnabled = sender.value != 0
            targetButton?.setProp("strokeWidth", NSNumber(value: Int(sliderStrokeWidth?.value ?? 0)))
        } else {
            sender.setValue(Float(Int(sender.value)), animated: false)
            targetButton?.setProp("cornerRadius", NSNumber(value: Int(sliderCornerRadius?.value ?? 0)))
            targetButton?.setProp("opacity", NSNumber(value: (sliderOpacity?.value ?? 0) / 100.0))
        }
        targetButton?.update()
    }

    @objc func visibilityValueChanged(_ sender: UISegmentedControl) {
        targetButton?.setProp("displayInGame", NSNumber(value: sender.selectedSegmentIndex != VISIBILITY_IN_MENU))
        targetButton?.setProp("displayInMenu", NSNumber(value: sender.selectedSegmentIndex != VISIBILITY_IN_GAME))
    }

    // MARK: - UIPickerView stuff

    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
        let label: UILabel
        if let existing = view as? UILabel {
            label = existing
        } else {
            label = UILabel()
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.textAlignment = .center
        }
        label.text = self.pickerView(pickerView, titleForRow: row, forComponent: component)
        return label
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        func title(_ component: Int) -> String {
            let index = pickerView.selectedRow(inComponent: component)
            return index >= 0 && index < keyCodeMap.count ? "\(keyCodeMap[index])" : ""
        }
        editMapping?.text = "1: \(title(0))\n2: \(title(1))\n3: \(title(2))\n4: \(title(3))"

        let keycodes = targetButton?.prop("keycodes") as? NSMutableArray
        for i in 0..<4 {
            guard let picker = pickerMapping, let keycodes = keycodes, i < keycodes.count else { continue }
            let index = picker.selectedRow(inComponent: i)
            if index >= 0 && index < keyValueMap.count {
                keycodes.replaceObject(at: i, with: keyValueMap[index])
            }
        }
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 4
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return keyCodeMap.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        guard row >= 0, row < keyCodeMap.count else { return nil }
        return keyCodeMap[row] as? String
    }

    @objc func closeTextField() {
        editMapping?.endEditing(true)
    }
}
