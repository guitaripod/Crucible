import UIKit

/// Base of the card cells. A cell only carries its `TVCardItem`, focus-dependent dimming and the
/// accessibility element; all drawing lives in `TVCardContentView`.
class TVCardCell: UICollectionViewCell {
    private(set) var item: TVCardItem?
    private var wasFocused = false

    class var style: TVCardStyle { .poster }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func registration<Cell: TVCardCell>(of type: Cell.Type) -> UICollectionView.CellRegistration<Cell, TVCardItem> {
        UICollectionView.CellRegistration<Cell, TVCardItem> { cell, _, item in
            cell.configure(with: item)
        }
    }

    /// A registration whose cards are drawn in whatever `style` returns when each is configured, for a grid that takes the
    /// shape of its artwork.
    static func registration<Cell: TVCardCell>(
        of type: Cell.Type,
        style: @escaping @MainActor () -> TVCardStyle
    ) -> UICollectionView.CellRegistration<Cell, TVCardItem> {
        UICollectionView.CellRegistration<Cell, TVCardItem> { cell, _, item in
            cell.configure(with: item, style: style())
        }
    }

    /// Shows `item` in `style`, or in the cell's own style when none is given.
    func configure(with item: TVCardItem, style: TVCardStyle? = nil) {
        self.item = item
        contentConfiguration = TVCardConfiguration(item: item, style: style ?? Self.style)
        accessibilityLabel = item.spokenLabel
        accessibilityValue = item.spokenValue
        accessibilityHint = item.accessibilityHint
        setNeedsUpdateConfiguration()
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        let alpha = item?.isDimmed == true && !state.isFocused ? TVMetrics.Card.watchedDimming : 1
        let focusChanged = state.isFocused != wasFocused
        wasFocused = state.isFocused
        guard alpha != contentView.alpha else { return }
        guard focusChanged, window != nil else {
            contentView.layer.removeAnimation(forKey: "opacity")
            contentView.alpha = alpha
            return
        }
        TVMotion.animate(TVMetrics.Duration.focus, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.contentView.alpha = alpha
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({
            self.contentView.layoutIfNeeded()
        })
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        wasFocused = false
        contentView.layer.removeAnimation(forKey: "opacity")
        contentView.alpha = 1
    }
}

/// A 2:3 poster with its title and subtitle underneath (movies, shows, anything with portrait art), or a card
/// of another shape captioned the same way when its grid takes the shape of its artwork.
final class TVPosterCell: TVCardCell {
    override class var style: TVCardStyle { .poster }

    static func registration() -> UICollectionView.CellRegistration<TVPosterCell, TVCardItem> {
        registration(of: TVPosterCell.self)
    }

    static func registration(style: @escaping @MainActor () -> TVCardStyle) -> UICollectionView.CellRegistration<TVPosterCell, TVCardItem> {
        registration(of: TVPosterCell.self, style: style)
    }
}

/// A 16:9 card for Continue Watching and Up Next: art with a progress bar, title and a status line.
final class TVLandscapeCell: TVCardCell {
    override class var style: TVCardStyle { .landscape }

    static func registration() -> UICollectionView.CellRegistration<TVLandscapeCell, TVCardItem> {
        registration(of: TVLandscapeCell.self)
    }
}

/// A 16:9 episode thumbnail with an eyebrow ("UP NEXT"), a two-line title and a runtime line.
final class TVEpisodeCell: TVCardCell {
    override class var style: TVCardStyle { .episode }

    static func registration() -> UICollectionView.CellRegistration<TVEpisodeCell, TVCardItem> {
        registration(of: TVEpisodeCell.self)
    }
}

/// A circular avatar with a name and a role underneath (cast and crew).
final class TVPersonCell: TVCardCell {
    override class var style: TVCardStyle { .person }

    static func registration() -> UICollectionView.CellRegistration<TVPersonCell, TVCardItem> {
        registration(of: TVPersonCell.self)
    }
}
