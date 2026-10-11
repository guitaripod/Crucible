import CrucibleCore
import CrucibleDesign
import UIKit

extension LibraryGridOptions {
    static func optionsImage(filtering: Bool) -> UIImage? {
        UIImage(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
    }
}

/// The trailing "grid size" control shared by the library host and stand-alone grids. The menu is
/// built lazily on every open so its checkmark always reflects the stored preference.
@MainActor
enum LibraryGridSizeMenu {
    static func barButtonItem(onChange: @escaping @MainActor @Sendable () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.grid.2x2"), menu: menu(onChange: onChange))
        item.accessibilityLabel = "Grid Size"
        return item
    }

    static func menu(onChange: @escaping @MainActor @Sendable () -> Void) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { completion in
            let current = Preferences.libraryColumns
            completion([
                action(title: "Large (2 columns)", symbol: "square.grid.2x2", columns: 2, current: current, onChange: onChange),
                action(title: "Compact (3 columns)", symbol: "square.grid.3x3", columns: 3, current: current, onChange: onChange),
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
            guard Preferences.libraryColumns != columns else { return }
            Preferences.libraryColumns = columns
            Haptics.selection()
            AppLogger.info("Library grid columns -> \(columns)", .ui)
            onChange()
        }
    }
}
