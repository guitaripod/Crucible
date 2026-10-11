import UIKit

/// The collection view every tvOS screen uses. It lets focus-grown cards draw outside their cells,
/// remembers the last focused item of each row, and turns Play/Pause on a focused item into a
/// callback (`onPlayPause`), the way the Apple TV app plays what is under the cursor.
class TVCollectionView: UICollectionView {
    /// Called with the index path of the focused item when the user presses Play/Pause.
    var onPlayPause: (@MainActor (IndexPath) -> Void)?

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        backgroundColor = .clear
        clipsToBounds = false
        remembersLastFocusedIndexPath = true
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        isDirectionalLockEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .playPause }),
              let onPlayPause,
              let indexPath = TVPlayPauseShortcut.focusedIndexPath(in: self)
        else {
            super.pressesEnded(presses, with: event)
            return
        }
        onPlayPause(indexPath)
    }
}

/// Resolves what a Play/Pause press refers to: the item under the focus cursor.
@MainActor
enum TVPlayPauseShortcut {
    static func focusedIndexPath(in collectionView: UICollectionView) -> IndexPath? {
        guard let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView else { return nil }
        var candidate: UIView? = focused
        while let view = candidate {
            if let cell = view as? UICollectionViewCell { return collectionView.indexPath(for: cell) }
            candidate = view.superview
        }
        return nil
    }
}

/// Remembers the last focused item of a screen so coming back (Back from a detail) lands where the
/// user left. `remembersLastFocusedIndexPath` covers movement inside one screen; this survives the
/// screen being popped and re-shown.
@MainActor
final class TVFocusMemory {
    private(set) var indexPath: IndexPath?

    func record(_ context: UICollectionViewFocusUpdateContext) {
        if let next = context.nextFocusedIndexPath {
            indexPath = next
        }
    }

    /// The remembered item if it still exists, for `indexPathForPreferredFocusedView(in:)`.
    func preferredIndexPath(in collectionView: UICollectionView) -> IndexPath? {
        guard let indexPath,
              indexPath.section < collectionView.numberOfSections,
              indexPath.item < collectionView.numberOfItems(inSection: indexPath.section)
        else { return nil }
        return indexPath
    }

    func reset() {
        indexPath = nil
    }
}

/// Long-press on Select opens the context menu: tvOS routes it through
/// `collectionView(_:contextMenuConfigurationForItemsAt:point:)`. Screens implement that delegate
/// method and return `TVContextMenu.configuration(menu)`.
@MainActor
enum TVContextMenu {
    static func configuration(identifier: NSCopying? = nil, menu: UIMenu?) -> UIContextMenuConfiguration? {
        guard let menu else { return nil }
        return UIContextMenuConfiguration(identifier: identifier, previewProvider: nil) { _ in menu }
    }
}
