import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

extension LibraryGridOptions {
    static func optionsImage(filtering: Bool) -> UIImage? {
        UIImage(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
    }
}

/// The trailing "grid size" control shared by the library host and stand-alone grids. The menu is
/// built lazily on every open so its checkmark always reflects the stored preference, and each
/// choice names the columns it gives at the grid's current width (`width`), which on a large
/// screen is more than the phone's two or three.
@MainActor
enum LibraryGridSizeMenu {
    static func barButtonItem(
        width: @escaping @MainActor () -> CGFloat,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.grid.2x2"), menu: menu(width: width, onChange: onChange))
        item.accessibilityLabel = "Grid Size"
        return item
    }

    static func menu(width: @escaping @MainActor () -> CGFloat, onChange: @escaping @MainActor @Sendable () -> Void) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { completion in
            let current = Preferences.libraryColumns
            let large = Theme.gridColumns(forWidth: width(), preferred: 2)
            let compact = Theme.gridColumns(forWidth: width(), preferred: 3)
            completion([
                action(title: "Large (\(large) columns)", symbol: "square.grid.2x2", columns: 2, current: current, onChange: onChange),
                action(title: "Compact (\(compact) columns)", symbol: "square.grid.3x3", columns: 3, current: current, onChange: onChange),
            ])
        }
        return UIMenu(title: "Grid Size", children: [deferred])
    }

    private static func action(
        title: String,
        symbol: String,
        columns: Int,
        current: Int,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol), state: current == columns ? .on : .off) { _ in
            guard set(columns) else { return }
            onChange()
        }
    }

    /// Stores the column preference; false when it already held `columns`.
    @discardableResult
    static func set(_ columns: Int) -> Bool {
        guard Preferences.libraryColumns != columns else { return false }
        Preferences.libraryColumns = columns
        Haptics.selection()
        MidgarLog.info("Library grid columns -> \(columns)", category: .ui)
        return true
    }
}
