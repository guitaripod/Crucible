import UIKit

/// Hosts one view filling the cell. The cell never takes focus itself; focus goes to whatever
/// focusable view it hosts. Use it for a button row, a stats panel or any view that is not a card.
final class TVHostCell: UICollectionViewCell {
    private(set) var hosted: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard let hosted else { return [] }
        return (hosted.firstFocusableView ?? hosted.preferredFocusEnvironments.first).map { [$0] } ?? []
    }

    /// Replaces the hosted view, pinned to the cell with `insets`.
    func host(_ view: UIView, insets: NSDirectionalEdgeInsets = .zero) {
        hosted?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -insets.bottom),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.leading),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.trailing),
        ])
        hosted = view
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hosted?.removeFromSuperview()
        hosted = nil
    }

    /// `build` makes the view for an item; it runs on every dequeue.
    static func registration<Item: Hashable>(
        insets: NSDirectionalEdgeInsets = .zero,
        build: @escaping @MainActor (Item) -> UIView
    ) -> UICollectionView.CellRegistration<TVHostCell, Item> {
        UICollectionView.CellRegistration<TVHostCell, Item> { cell, _, item in
            cell.host(build(item), insets: insets)
        }
    }
}

extension UIView {
    /// The view itself if it can take focus, otherwise the first focusable descendant in layout order.
    var firstFocusableView: UIFocusEnvironment? {
        if canBecomeFocused { return self }
        for child in subviews where !child.isHidden {
            if let found = child.firstFocusableView { return found }
        }
        return nil
    }
}
