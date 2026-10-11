#if DEBUG
import CrucibleDesign
import UIKit

/// The button recipes in a row, hosted by a `TVHostCell`.
final class GalleryButtonsView: UIStackView {
    init() {
        super.init(frame: .zero)
        let menu = UIMenu(title: "", children: ["English (Atmos 5.1)", "French (Stereo)"].map { UIAction(title: $0) { _ in } })
        let buttons = [
            TVButton.make(.primary, title: "Resume · 42m left", symbol: "play.fill"),
            TVButton.make(.glass, title: "Start Over", symbol: "gobackward"),
            TVButton.make(.glass, title: "Mark Watched", symbol: "checkmark"),
            TVButton.menuButton(title: "Audio", menu: menu),
            TVButton.make(.plain, title: "More", symbol: "chevron.right", symbolTrailing: true),
        ]
        for (index, button) in buttons.enumerated() {
            button.accessibilityIdentifier = "gallery.button.\(index)"
            addArrangedSubview(button)
        }
        addArrangedSubview(UIView())
        axis = .horizontal
        alignment = .center
        spacing = Theme.Space.m
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }
}

/// Specimens of the shared helpers: font recipes, status dots and rows, a chip row, an in-place menu
/// button and the alert helper. Hosted by a `TVHostCell`.
final class GalleryHelpersView: UIView {
    private let sortMenuButton = UIButton(type: .system)
    private let chipRow = TVChipRow()
    private let statusRow = TVStatusRow()
    private let errorRow = TVStatusRow()

    init(onAlert: @escaping @MainActor () -> Void) {
        super.init(frame: .zero)
        let left = UIStackView(arrangedSubviews: fontSpecimens() + [dotsRow()])
        left.axis = .vertical
        left.alignment = .leading
        left.spacing = Theme.Space.s

        configureChips()
        configureSortMenu()
        statusRow.show("Connecting to Marcus-PC…", isBusy: true)
        errorRow.show("Couldn’t reach Marcus-PC. Check the connection.", tone: .error)
        let alert = TVButton.make(.glass, title: "Show Alert", symbol: "exclamationmark.bubble") { onAlert() }
        alert.accessibilityIdentifier = "gallery.helpers.alert"

        let controls = UIStackView(arrangedSubviews: [chipRow, sortMenuButton, alert, statusRow, errorRow])
        controls.axis = .vertical
        controls.alignment = .leading
        controls.spacing = Theme.Space.m

        let columns = UIStackView(arrangedSubviews: [left, controls])
        columns.axis = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = Theme.Space.l
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: topAnchor),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func fontSpecimens() -> [UIView] {
        let specimens: [(String, UIFont, UIColor)] = [
            ("control · Resume · 42m left", TVFont.control, Theme.Color.label),
            ("cardTitle · The Last Lighthouse", TVFont.cardTitle, Theme.Color.label),
            ("cardSubtitle · S1 · E4 · 38m left", TVFont.cardSubtitle, Theme.Color.labelSecondary),
            ("EYEBROW · UP NEXT", TVFont.eyebrow, Theme.Color.accentText),
            ("mono · 7K4Q 0123", TVFont.mono(size: 38, weight: .semibold), Theme.Color.label),
        ]
        return specimens.map { text, font, color in
            let label = UILabel()
            label.text = text
            label.font = font
            label.textColor = color
            return label
        }
    }

    private func dotsRow() -> UIView {
        let colors: [(UIColor, String)] = [(Theme.Color.statusOK, "Local"), (Theme.Color.accent, "Remote"), (Theme.Color.destructive, "Relay")]
        let items = colors.map { color, name -> UIView in
            let dot = TVStatusDot(color: color)
            let label = UILabel()
            label.text = name
            label.font = TVFont.cardSubtitle
            label.textColor = Theme.Color.labelSecondary
            let stack = UIStackView(arrangedSubviews: [dot, label])
            stack.alignment = .center
            stack.spacing = Theme.Space.xs
            return stack
        }
        let bigDot = TVStatusDot(color: Theme.Color.statusOK, diameter: TVMetrics.Dot.large)
        let row = UIStackView(arrangedSubviews: items + [bigDot])
        row.alignment = .center
        row.spacing = Theme.Space.m
        return row
    }

    private func configureChips() {
        chipRow.setItems([
            TVChipItem(id: "helpers.all", title: "All", isSelected: true),
            TVChipItem(id: "helpers.week", title: "Week"),
            TVChipItem(id: "helpers.month", title: "Month"),
            TVChipItem(id: "helpers.year", title: "Year", symbol: "calendar"),
        ])
        chipRow.onSelect = { [weak self] item in self?.chipRow.select(id: item.id) }
    }

    private func configureSortMenu() {
        let titles = ["Title", "Year", "Recently Added"]
        func apply(_ selected: String) {
            let actions = titles.map { title in
                UIAction(title: title, state: title == selected ? .on : .off) { _ in apply(title) }
            }
            TVButton.configure(menu: UIMenu(title: "", children: actions), title: "Sort: \(selected)", style: .glass, on: sortMenuButton)
        }
        apply("Title")
        sortMenuButton.accessibilityIdentifier = "gallery.helpers.menu"
    }
}
#endif
