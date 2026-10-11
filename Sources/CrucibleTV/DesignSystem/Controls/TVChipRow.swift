import CrucibleDesign
import UIKit

/// A horizontal row of chips for screens that are not collection lists (the Library header, the
/// Statistics range bar). Chips are real buttons, so they take the system focus; selection is a press,
/// never focus. Collection screens use `TVChipCell` instead.
final class TVChipRow: UIStackView {
    private(set) var items: [TVChipItem] = []
    private var buttons: [String: UIButton] = [:]
    var onSelect: (@MainActor (TVChipItem) -> Void)?

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = Theme.Space.xs
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func button(for id: String) -> UIButton? { buttons[id] }

    /// Shows `items`. When the set of identifiers is unchanged only selection and titles are
    /// updated in place, so a focused chip keeps focus while another one is selected.
    func setItems(_ newItems: [TVChipItem]) {
        let sameIdentifiers = newItems.map(\.id) == items.map(\.id)
        items = newItems
        guard sameIdentifiers else {
            rebuild()
            return
        }
        newItems.forEach(refresh)
    }

    /// Selects the chip with `id` and deselects the others.
    func select(id: String) {
        setItems(items.map { item in
            var copy = item
            copy.isSelected = item.id == id
            return copy
        })
    }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        for item in items {
            let button = UIButton(type: .system)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.accessibilityIdentifier = "tv.chip.\(item.id)"
            let id = item.id
            button.addAction(UIAction { [weak self] _ in
                guard let self, let current = self.items.first(where: { $0.id == id }) else { return }
                self.onSelect?(current)
            }, for: .primaryActionTriggered)
            buttons[item.id] = button
            addArrangedSubview(button)
            refresh(item)
        }
    }

    private func refresh(_ item: TVChipItem) {
        guard let button = buttons[item.id] else { return }
        button.configuration = TVButton.configuration(.chip(selected: item.isSelected), title: item.title, symbol: item.symbol)
        button.accessibilityLabel = item.title
        button.accessibilityTraits = item.isSelected ? [.button, .selected] : .button
    }
}
