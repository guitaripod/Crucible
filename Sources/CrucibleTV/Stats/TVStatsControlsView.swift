import CrucibleDesign
import CrucibleStats
import UIKit

/// The top of the Statistics screen: the shared screen title with the "watching since" line, the
/// Week / Month / Year / All chips and the Libraries filter menu. Selection is a press, never focus.
///
/// Statistics beyond the Week range and the Libraries filter are Crucible Pro. While `showsLocks` is on, the Month, Year and
/// All chips and the Libraries button carry a lock and report a press through `onLocked` instead of changing anything; the
/// screen opens the paywall and, once Pro is on, selects the range itself.
final class TVStatsControlsView: UIView {
    var onRange: (@MainActor (StatsRange) -> Void)?
    var onLocked: (@MainActor (StatsLock) -> Void)?

    enum StatsLock: Equatable {
        case range(StatsRange)
        case libraries
    }

    var showsLocks = false {
        didSet {
            guard showsLocks != oldValue else { return }
            chipRow.setItems(chipItems())
            updateLibraries(filter)
        }
    }

    private let title = TVScreenTitleView(clearsTabBar: false)
    private let chipRow = TVChipRow()
    private let librariesSlot = UIView()
    private var librariesButton: UIButton?
    private var librariesLockAction: UIAction?
    private var filter = StatsLibraryFilter.current()
    private var range = StatsRange.year

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.configure(TVScreenTitleContent(title: "Statistics"))

        chipRow.spacing = Theme.Space.s
        chipRow.setItems(chipItems())
        for candidate in StatsRange.allCases {
            chipRow.button(for: Self.chipID(candidate))?.accessibilityIdentifier = "stats.range.\(candidate.title.lowercased())"
        }
        chipRow.onSelect = { [weak self] item in
            guard let chosen = StatsRange.allCases.first(where: { Self.chipID($0) == item.id }) else { return }
            self?.choose(chosen)
        }

        let controls = UIStackView(arrangedSubviews: [chipRow, librariesSlot])
        controls.axis = .horizontal
        controls.spacing = Theme.Space.m
        controls.alignment = .center

        let row = UIStackView(arrangedSubviews: [title, UIView(), controls])
        row.axis = .horizontal
        row.alignment = .bottom
        row.spacing = Theme.Space.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [chipRow.button(for: Self.chipID(range))].compactMap { $0 }
    }

    func configure(range: StatsRange, since: String?, filter: StatsLibraryFilter) {
        self.range = range
        title.configure(TVScreenTitleContent(title: "Statistics", summary: since))
        chipRow.setItems(chipItems())
        updateLibraries(filter)
    }

    /// Marks `range` as the chosen chip without reporting it, for a range the screen selected itself.
    func select(range: StatsRange) {
        self.range = range
        chipRow.select(id: Self.chipID(range))
    }

    static func isLocked(_ range: StatsRange, showsLocks: Bool) -> Bool {
        showsLocks && range != .week
    }

    private static func chipID(_ range: StatsRange) -> String {
        "stats-\(range.title.lowercased())"
    }

    private func chipItems() -> [TVChipItem] {
        StatsRange.allCases.map { candidate in
            let locked = Self.isLocked(candidate, showsLocks: showsLocks)
            return TVChipItem(
                id: Self.chipID(candidate),
                title: candidate.title,
                symbol: locked ? "lock.fill" : nil,
                isSelected: candidate == range,
                accessibilityLabel: locked ? "\(candidate.title), locked" : nil,
                accessibilityHint: locked ? "Requires Crucible Pro" : nil
            )
        }
    }

    private func choose(_ chosen: StatsRange) {
        if Self.isLocked(chosen, showsLocks: showsLocks) {
            onLocked?(.range(chosen))
            return
        }
        guard chosen != range else { return }
        range = chosen
        chipRow.select(id: Self.chipID(chosen))
        onRange?(chosen)
    }

    /// Brings the Libraries menu up to date in place, so a menu that is open survives a toggle; the
    /// button disappears when there is nothing to choose between.
    func updateLibraries(_ filter: StatsLibraryFilter) {
        self.filter = filter
        librariesSlot.isHidden = !filter.isAvailable
        guard filter.isAvailable else {
            librariesButton?.removeFromSuperview()
            librariesButton = nil
            return
        }
        let title = Self.librariesTitle(filter)
        if let button = librariesButton {
            style(button, filter: filter, title: title)
            return
        }
        let button = UIButton(type: .system)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        style(button, filter: filter, title: title)
        button.accessibilityIdentifier = "stats.libraries"
        button.translatesAutoresizingMaskIntoConstraints = false
        librariesSlot.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: librariesSlot.topAnchor),
            button.bottomAnchor.constraint(equalTo: librariesSlot.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: librariesSlot.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: librariesSlot.trailingAnchor),
        ])
        librariesButton = button
    }

    /// A menu button for Pro; for a free install a plain button with a lock that asks for the paywall instead of opening a menu.
    private func style(_ button: UIButton, filter: StatsLibraryFilter, title: String) {
        if let lockAction = librariesLockAction {
            button.removeAction(lockAction, for: .primaryActionTriggered)
            librariesLockAction = nil
        }
        button.accessibilityValue = filter.accessibilityValue
        guard showsLocks else {
            TVButton.configure(menu: Self.menu(for: filter), title: title, style: .glass, on: button)
            button.accessibilityHint = nil
            return
        }
        button.menu = nil
        button.showsMenuAsPrimaryAction = false
        button.configuration = TVButton.configuration(.glass, title: title, symbol: "lock.fill")
        button.accessibilityLabel = "\(title), locked"
        button.accessibilityHint = "Requires Crucible Pro"
        let lockAction = UIAction { [weak self] _ in self?.onLocked?(.libraries) }
        librariesLockAction = lockAction
        button.addAction(lockAction, for: .primaryActionTriggered)
    }

    private static func librariesTitle(_ filter: StatsLibraryFilter) -> String {
        filter.isCustomized ? "Libraries · Filtered" : "Libraries"
    }

    private static func menu(for filter: StatsLibraryFilter) -> UIMenu {
        let toggles = filter.entries.map { entry in
            UIAction(
                title: entry.title,
                subtitle: entry.subtitle,
                image: UIImage(systemName: entry.symbol),
                attributes: entry.isLocked ? [.disabled] : [],
                state: entry.isIncluded ? .on : .off
            ) { _ in
                filter.toggle(entry)
            }
        }
        var children: [UIMenuElement] = [UIMenu(title: "Include in Statistics", options: .displayInline, children: toggles)]
        if filter.hasOverrides {
            children.append(UIAction(title: "Reset to Plex Defaults", image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                filter.resetToPlexDefaults()
            })
        }
        return UIMenu(children: children)
    }
}
