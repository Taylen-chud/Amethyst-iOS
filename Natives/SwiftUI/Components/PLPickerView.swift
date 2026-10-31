import UIKit
import ObjectiveC

/// Delegate of `PLPickerView`: fills the image view of every row.
@objc(PLPickerViewDelegate)
protocol PLPickerViewDelegate: UIPickerViewDelegate {
    func pickerView(_ pickerView: PLPickerView, enumerateImageView imageView: UIImageView, forRow row: Int, forComponent component: Int)
}

@objc(PLPickerView)
@objcMembers
class PLPickerView: UIPickerView {
    private static let cellSelector = NSSelectorFromString("tableView:cellForRowAtIndexPath:")
    private static let columnSelector = NSSelectorFromString("tableViewForColumn:")

    @objc(tableView:cellForRowAtIndexPath:)
    func pickerTableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // super.tableView:cellForRowAtIndexPath:
        guard let superclass = class_getSuperclass(PLPickerView.self),
              let method = class_getInstanceMethod(superclass, PLPickerView.cellSelector) else {
            return UITableViewCell()
        }
        typealias CellFunc = @convention(c) (AnyObject, Selector, UITableView, NSIndexPath) -> Unmanaged<UITableViewCell>
        let function = unsafeBitCast(method_getImplementation(method), to: CellFunc.self)
        let cell = function(self, PLPickerView.cellSelector, tableView, indexPath as NSIndexPath).takeUnretainedValue()

        if let imageView = cell.imageView {
            imageView.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
            imageView.isSizeFixed = true
            imageView.layer.magnificationFilter = .nearest
            (delegate as? PLPickerViewDelegate)?.pickerView(self, enumerateImageView: imageView, forRow: indexPath.row, forComponent: indexPath.section)
        }
        return cell
    }

    @objc(imageAtRow:column:)
    func image(atRow row: Int, column: Int) -> UIImage? {
        let indexPath = IndexPath(row: row, section: column)
        guard responds(to: PLPickerView.columnSelector), let imp = method(for: PLPickerView.columnSelector) else { return nil }
        typealias ColumnFunc = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<UITableView>?
        let function = unsafeBitCast(imp, to: ColumnFunc.self)
        guard let table = function(self, PLPickerView.columnSelector, 0)?.takeUnretainedValue() else { return nil }
        return pickerTableView(table, cellForRowAt: indexPath).imageView?.image
    }
}
