import UIKit

struct TVChipItem: Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String?
    var isSelected: Bool

    init(id: String, title: String, symbol: String? = nil, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
    }
}

/// A chip in a `TVShelf.chips` row. The chip is a real `UIButton`, so it gets the system focus and
/// press behaviour; the cell itself is not focusable. Selection is explicit (press), never focus.
final class TVChipCell: UICollectionViewCell {
    private let button = UIButton(type: .system)
    private var item: TVChipItem?
    private var onSelect: (@MainActor (TVChipItem) -> Void)?
    private var actionIdentifier: UIAction.Identifier?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    /// `menu` supplies an optional long-press menu for a chip (nil for none).
    static func registration(
        onSelect: @escaping @MainActor (TVChipItem) -> Void,
        menu: (@MainActor (TVChipItem) -> UIMenu?)? = nil
    ) -> UICollectionView.CellRegistration<TVChipCell, TVChipItem> {
        UICollectionView.CellRegistration<TVChipCell, TVChipItem> { cell, _, item in
            cell.configure(with: item, onSelect: onSelect, menu: menu)
        }
    }

    func configure(
        with item: TVChipItem,
        onSelect: @escaping @MainActor (TVChipItem) -> Void,
        menu: (@MainActor (TVChipItem) -> UIMenu?)? = nil
    ) {
        self.item = item
        self.onSelect = onSelect
        button.menu = menu?(item)
        button.configuration = TVButton.configuration(.chip(selected: item.isSelected), title: item.title, symbol: item.symbol)
        button.accessibilityLabel = item.title
        button.accessibilityTraits = item.isSelected ? [.button, .selected] : .button
        button.accessibilityIdentifier = "tv.chip.\(item.id)"
        if let identifier = actionIdentifier {
            button.removeAction(identifiedBy: identifier, for: .primaryActionTriggered)
        }
        let action = UIAction { [weak self] _ in
            guard let self, let item = self.item else { return }
            self.onSelect?(item)
        }
        actionIdentifier = action.identifier
        button.addAction(action, for: .primaryActionTriggered)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [button] }
}
