import CrucibleCore
import CrucibleDesign
import CrucibleStats
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

    func updateLibrariesMenu() {
        guard let item = navigationItem.rightBarButtonItem else { return }
        let filter = StatsLibraryFilter.current()
        item.isHidden = !filter.isAvailable
        guard !ProAccess.shared.showsLocks else {
            showLockedLibraries(on: item, symbol: filter.symbol)
            return
        }
        item.primaryAction = nil
        item.image = UIImage(systemName: filter.symbol)
        item.accessibilityValue = filter.accessibilityValue

        let toggles = filter.entries.map { entry -> UIAction in
            UIAction(
                title: entry.title,
                subtitle: entry.subtitle,
                image: UIImage(systemName: entry.symbol),
                attributes: entry.isLocked ? [.keepsMenuPresented, .disabled] : .keepsMenuPresented,
                state: entry.isIncluded ? .on : .off
            ) { _ in
                Haptics.selection()
                filter.toggle(entry)
            }
        }
        var children: [UIMenuElement] = [UIMenu(title: "Include in Statistics", options: .displayInline, children: toggles)]
        if filter.hasOverrides {
            children.append(UIAction(title: "Reset to Plex Defaults", image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                filter.resetToPlexDefaults()
            })
        }
        item.menu = UIMenu(children: children)
    }

    /// The library filter is Pro: a free install sees it locked, and tapping it opens the paywall instead of the menu.
    private func showLockedLibraries(on item: UIBarButtonItem, symbol: String) {
        item.menu = nil
        item.image = ProLock.badged(symbol: symbol)
        item.accessibilityValue = "Requires Crucible Pro"
        item.primaryAction = UIAction(title: "Libraries", image: ProLock.badged(symbol: symbol)) { _ in
            ProAccess.shared.requestUnlock(.fullStatistics)
        }
    }
}
