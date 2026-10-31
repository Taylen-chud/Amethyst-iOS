import UIKit

private class PickViewController: UIViewController {
    weak var textField: UITextField?

    override func loadView() {
        super.loadView()
        if let accessory = textField?.inputAccessoryView {
            view.addSubview(accessory)
        }
        if let inputView = textField?.inputView {
            view.addSubview(inputView)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let insets = view.safeAreaInsets
        let frame = CGRect(
            x: insets.left,
            y: insets.top,
            width: min(view.frame.size.width - insets.right, preferredContentSize.width),
            height: min(view.frame.size.height - insets.bottom, preferredContentSize.height))
        let accessoryFrame = CGRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: textField?.inputAccessoryView?.frame.size.height ?? 0)
        textField?.inputAccessoryView?.frame = accessoryFrame
        // The Obj-C original subtracted `self.inputAccessoryView.frame` of THIS controller here (always nil, so 0).
        textField?.inputView?.frame = CGRect(
            x: frame.origin.x,
            y: accessoryFrame.maxY,
            width: frame.size.width,
            height: frame.size.height - (inputAccessoryView?.frame.maxY ?? 0))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let textField = textField {
            textField.delegate?.textFieldDidEndEditing?(textField)
        }
    }
}

/// Text field that is edited through a picker (its inputView) and never shows a caret or a selection.
@objc(PickTextField)
@objcMembers
class PickTextField: UITextField {
    private var vc: PickViewController?
    private var doneButton: UIButton?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return false
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        return .null
    }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        return []
    }

    var prefersPopoverPresentation: Bool {
        return hasLiquidGlass || ProcessInfo.processInfo.isMacCatalystApp
    }

    /// Obj-C: `-setupDoneButtonWithTarget:action:`
    @objc(setupDoneButtonWithTarget:action:)
    func setupDoneButton(target: Any?, action: Selector) {
        if prefersPopoverPresentation { return }
        var toolbar = inputAccessoryView as? UIToolbar
        if toolbar == nil {
            let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            let newToolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: frame.size.width, height: 44))
            newToolbar.items = [flexibleSpace]
            inputAccessoryView = newToolbar
            toolbar = newToolbar
        }
        let editDoneButton = UIBarButtonItem(barButtonSystemItem: .done, target: target, action: action)
        toolbar?.items = (toolbar?.items ?? []) + [editDoneButton]
    }

    override func becomeFirstResponder() -> Bool {
        // iOS 26 uses popover as well
        if !prefersPopoverPresentation {
            return super.becomeFirstResponder()
        }

        let pickVC = PickViewController()
        vc = pickVC
        pickVC.modalPresentationStyle = .popover
        let width = min(400, min(window?.frame.size.width ?? 400, window?.frame.size.height ?? 400))
        pickVC.preferredContentSize = CGSize(width: width, height: 250)
        pickVC.textField = self

        if let popover = pickVC.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = frame
        }

        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard let showingVC = responder as? UIViewController else { return true }
        showingVC.present(pickVC, animated: true)
        delegate?.textFieldDidBeginEditing?(self)

        return true
    }

    override func endEditing(_ force: Bool) -> Bool {
        if !ProcessInfo.processInfo.isMacCatalystApp {
            return super.endEditing(force)
        }

        vc?.dismiss(animated: true)
        delegate?.textFieldDidEndEditing?(self)
        vc = nil
        return true
    }
}
