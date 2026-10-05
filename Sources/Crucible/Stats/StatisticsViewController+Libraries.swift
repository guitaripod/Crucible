@preconcurrency import UIKit

extension StatisticsViewController {
    /// A filter button in the navigation bar whose menu switches libraries in and out of the
    /// statistics; it shares its choices with Home and Settings.
    func configureLibrariesItem() {
        let item = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: nil)
        item.accessibilityLabel = "Libraries"
        navigationItem.rightBarButtonItem = item
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.updateLibrariesMenu()
            self?.load(animateHero: false)
        }
        updateLibrariesMenu()
    }

    private func updateLibrariesMenu() {
        guard let item = navigationItem.rightBarButtonItem else { return }
        let libraries = LibraryVisibility.libraries
        item.isHidden = libraries.count < 2
        item.image = UIImage(systemName: LibraryVisibility.isCustomized ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        item.accessibilityValue = LibraryVisibility.isCustomized ? "Filtered" : "All libraries"

        let includedCount = libraries.filter { LibraryVisibility.isIncluded($0.id) }.count
        let toggles = libraries.map { library -> UIAction in
            let isOn = LibraryVisibility.isIncluded(library.id)
            let isLast = isOn && includedCount <= 1
            return UIAction(
                title: library.title,
                subtitle: library.hiddenOnPlex ? "Hidden from Home in Plex" : nil,
                image: UIImage(systemName: library.symbol),
                attributes: isLast ? [.keepsMenuPresented, .disabled] : .keepsMenuPresented,
                state: isOn ? .on : .off
            ) { _ in
                Haptics.selection()
                LibraryVisibility.setIncluded(library.id, !isOn)
            }
        }
        var children: [UIMenuElement] = [UIMenu(title: "Include in Statistics", options: .displayInline, children: toggles)]
        if LibraryVisibility.hasOverrides {
            children.append(UIAction(title: "Reset to Plex Defaults", image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                LibraryVisibility.resetToPlexDefaults()
            })
        }
        item.menu = UIMenu(children: children)
    }
}
