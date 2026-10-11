import CrucibleDesign
import CrucibleStats
import UIKit

/// The top of the Statistics screen: the shared screen title with the "watching since" line, the
/// Week / Month / Year / All chips and the Libraries filter menu. Selection is a press, never focus.
final class TVStatsControlsView: UIView {
    var onRange: (@MainActor (StatsRange) -> Void)?

    private let title = TVScreenTitleView(clearsTabBar: false)
    private let chipRow = TVChipRow()
    private let librariesSlot = UIView()
    private var librariesButton: UIButton?
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

    private static func chipID(_ range: StatsRange) -> String {
        "stats-\(range.title.lowercased())"
    }

    private func chipItems() -> [TVChipItem] {
        StatsRange.allCases.map { TVChipItem(id: Self.chipID($0), title: $0.title, isSelected: $0 == range) }
    }

    private func choose(_ chosen: StatsRange) {
        guard chosen != range else { return }
        range = chosen
        chipRow.select(id: Self.chipID(chosen))
        onRange?(chosen)
    }

    /// Brings the Libraries menu up to date in place, so a menu that is open survives a toggle; the
    /// button disappears when there is nothing to choose between.
    func updateLibraries(_ filter: StatsLibraryFilter) {
        librariesSlot.isHidden = !filter.isAvailable
        guard filter.isAvailable else {
            librariesButton?.removeFromSuperview()
            librariesButton = nil
            return
        }
        let menu = Self.menu(for: filter)
        let title = Self.librariesTitle(filter)
        if let button = librariesButton {
            TVButton.configure(menu: menu, title: title, style: .glass, on: button)
            button.accessibilityValue = filter.accessibilityValue
            return
        }
        let button = TVButton.menuButton(style: .glass, title: title, menu: menu)
        button.accessibilityValue = filter.accessibilityValue
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
