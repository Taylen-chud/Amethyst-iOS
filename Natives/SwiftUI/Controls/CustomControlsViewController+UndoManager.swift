import UIKit


extension CustomControlsViewController {
    private func list(_ key: String) -> NSMutableArray? {
        return ctrlView.layoutDictionary?.object(forKey: key) as? NSMutableArray
    }

    func doAddButton(_ button: ControlButton, atIndex index: Int) {
        let undo = undoManager

        if let sub = button as? ControlSubButton {
            undo?.setActionName(localize("custom_controls.button_menu.add_subbutton"))

            ctrlView.addSubview(button)
            if let drawer = sub.parentDrawer {
                drawer.buttons?.insert(button, at: index)
                (drawer.drawerData?.object(forKey: "buttonProperties") as? NSMutableArray)?.insert(button.properties as Any, at: index)
                drawer.syncButtons()
            }
        } else if let drawer = button as? ControlDrawer {
            undo?.setActionName(localize("custom_controls.control_menu.add_drawer"))

            for case let subButton as ControlSubButton in (drawer.buttons as? [Any] ?? []) {
                ctrlView.addSubview(subButton)
            }
            if let data = drawer.drawerData {
                list("mDrawerDataList")?.insert(data, at: index)
            }
            ctrlView.addSubview(button)
        } else if button is ControlJoystick {
            undo?.setActionName(localize("custom_controls.control_menu.add_joystick"))
            list("mJoystickDataList")?.insert(button.properties as Any, at: index)
            ctrlView.addSubview(button)
        } else {
            undo?.setActionName(localize("custom_controls.control_menu.add_button"))
            list("mControlDataList")?.insert(button.properties as Any, at: index)
            ctrlView.addSubview(button)
        }

        undo?.registerUndo(withTarget: self) { target in
            target.doRemoveButton(button)
        }
        if undo?.isUndoing == true {
            undo?.setActionName(localize("Remove"))
        }
    }

    func doRemoveButton(_ button: ControlButton) {
        var index = NSNotFound
        if let sub = button as? ControlSubButton {
            if let parent = sub.parentDrawer {
                let props = parent.drawerData?.object(forKey: "buttonProperties") as? NSMutableArray
                index = props?.index(of: button.properties as Any) ?? NSNotFound
                parent.buttons?.remove(button)
                props?.remove(button.properties as Any)
                parent.syncButtons()
            }
        } else if let drawer = button as? ControlDrawer {
            let drawers = list("mDrawerDataList")
            if let data = drawer.drawerData {
                index = drawers?.index(of: data) ?? NSNotFound
                drawers?.remove(data)
            }
            for case let subButton as UIView in (drawer.buttons as? [Any] ?? []) {
                subButton.removeFromSuperview()
            }
        } else if button is ControlJoystick {
            let joysticks = list("mJoystickDataList")
            index = joysticks?.index(of: button.properties as Any) ?? NSNotFound
            joysticks?.remove(button.properties as Any)
        } else {
            let controls = list("mControlDataList")
            index = controls?.index(of: button.properties as Any) ?? NSNotFound
            controls?.remove(button.properties as Any)
        }
        button.removeFromSuperview()
        resizeView.isHidden = true

        let undo = undoManager
        let removedIndex = index
        undo?.registerUndo(withTarget: self) { target in
            target.undoRemoveButton(button, atIndex: removedIndex)
        }
        if undo?.isUndoing != true {
            undo?.setActionName(localize("Remove"))
        }
    }

    func undoRemoveButton(_ button: ControlButton, atIndex index: Int) {
        let undo = undoManager
        if undo?.isUndoing != true {
            undo?.setActionName(localize("Remove"))
        }
        // The old code passed NSNotFound straight to insertObject:atIndex: (and crashed); append instead
        let count: Int
        if let sub = button as? ControlSubButton {
            count = (sub.parentDrawer?.drawerData?.object(forKey: "buttonProperties") as? NSArray)?.count ?? 0
        } else if let drawer = button as? ControlDrawer, drawer.drawerData != nil {
            _ = drawer
            count = list("mDrawerDataList")?.count ?? 0
        } else if button is ControlJoystick {
            count = list("mJoystickDataList")?.count ?? 0
        } else {
            count = list("mControlDataList")?.count ?? 0
        }
        doAddButton(button, atIndex: index == NSNotFound ? count : min(index, count))
    }

    func doMoveOrResizeButton(_ button: ControlButton, from: CGRect, to: CGRect) {
        let undo = undoManager
        undo?.registerUndo(withTarget: self) { target in
            target.doMoveOrResizeButton(button, from: to, to: from)
        }
        if undo?.isUndoing != true {
            if from.size.equalTo(to.size) {
                undo?.setActionName(localize("Move"))
            } else {
                undo?.setActionName(localize("Resize"))
            }
        }

        controlSnapAndAlign(button, x: to.origin.x, y: to.origin.y)
        button.setProp("width", NSNumber(value: Double(to.size.width)))
        button.setProp("height", NSNumber(value: Double(to.size.height)))
        button.update()
        resizeView.frame = CGRect(x: button.frame.maxX, y: button.frame.maxY,
                                  width: resizeView.frame.size.width, height: resizeView.frame.size.height)
    }

    func doUpdateButton(_ button: ControlButton, from: NSMutableDictionary, to: NSMutableDictionary) {
        let undo = undoManager
        undo?.registerUndo(withTarget: self) { target in
            target.doUpdateButton(button, from: to, to: from)
        }
        if undo?.isUndoing != true {
            undo?.setActionName(localize("Edit"))
        }

        for key in to.allKeys {
            if let key = key as? String {
                button.setProp(key, to.object(forKey: key))
            }
        }

        if let exception = AMECatchException({ button.update() }) {
            let oldX = from.object(forKey: "dynamicX")
            let oldY = from.object(forKey: "dynamicY")
            button.setProp("dynamicX", oldX)
            button.setProp("dynamicY", oldY)
            if let oldX = oldX { to.setObject(oldX, forKey: "dynamicX" as NSString) }
            if let oldY = oldY { to.setObject(oldY, forKey: "dynamicY" as NSString) }
            exception.raise()
        }
    }
}
