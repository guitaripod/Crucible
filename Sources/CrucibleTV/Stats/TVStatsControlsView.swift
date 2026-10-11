import CrucibleDesign
import CrucibleStats
import UIKit

/// The top of the Statistics screen: the title with the "watching since" line, the Week / Month /
/// Year / All chips, and the Libraries filter menu. Selection is a press, never focus.
final class TVStatsControlsView: UIView {
    var onRange: (@MainActor (StatsRange) -> Void)?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var chips: [StatsRange: UIButton] = [:]
    private let chipRow = UIStackView()
    private let librariesSlot = UIView()
    private var librariesButton: UIButton?
    private var range: StatsRange = .year

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = "Statistics"
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.accessibilityTraits = .header
        subtitleLabel.font = Theme.Font.callout
        subtitleLabel.textColor = Theme.Color.labelSecondary

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = Theme.Space.xxs

        chipRow.axis = .horizontal
        chipRow.spacing = Theme.Space.s
        chipRow.alignment = .center
        for candidate in StatsRange.allCases {
            let chip = TVButton.make(.chip(selected: false), title: candidate.title) { [weak self] in
                self?.choose(candidate)
            }
            chip.accessibilityIdentifier = "stats.range.\(candidate.title.lowercased())"
            chips[candidate] = chip
            chipRow.addArrangedSubview(chip)
        }

        let controls = UIStackView(arrangedSubviews: [chipRow, librariesSlot])
        controls.axis = .horizontal
        controls.spacing = Theme.Space.m
        controls.alignment = .center

        let row = UIStackView(arrangedSubviews: [titles, UIView(), controls])
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
        applySelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [chips[range]].compactMap { $0 }
    }

    func configure(range: StatsRange, subtitle: String?, filter: StatsLibraryFilter) {
        self.range = range
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        applySelection()
        updateLibraries(filter)
    }

    func select(_ range: StatsRange) {
        self.range = range
        applySelection()
    }

    private func choose(_ chosen: StatsRange) {
        guard chosen != range else { return }
        select(chosen)
        onRange?(chosen)
    }

    private func applySelection() {
        for (candidate, chip) in chips {
            TVButton.setChipSelected(candidate == range, on: chip)
        }
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
        if let button = librariesButton {
            button.menu = menu
            button.configuration?.title = Self.librariesTitle(filter)
            button.accessibilityValue = filter.accessibilityValue
            return
        }
        let button = TVButton.menuButton(title: Self.librariesTitle(filter), menu: menu)
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
