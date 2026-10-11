import UIKit

/// The collection view every tvOS screen uses. It lets focus-grown cards draw outside their cells,
/// remembers the last focused item of each row, and turns Play/Pause on a focused item into a
/// callback (`onPlayPause`), the way the Apple TV app plays what is under the cursor.
class TVCollectionView: UICollectionView {
    /// Called with the index path of the focused item when the user presses Play/Pause. The press is
    /// always consumed; prefer `playPauseHandler`, which can decline.
    final var onPlayPause: (@MainActor (IndexPath) -> Void)?

    /// Called with the index path of the focused item on Play/Pause; returns whether the screen
    /// handled it. When it declines, the press continues up the responder chain like any other.
    final var playPauseHandler: (@MainActor (IndexPath) -> Bool)?

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
              onPlayPause != nil || playPauseHandler != nil,
              let indexPath = TVPlayPauseShortcut.focusedIndexPath(in: self)
        else {
            super.pressesEnded(presses, with: event)
            return
        }
        if let playPauseHandler, playPauseHandler(indexPath) { return }
        if let onPlayPause {
            onPlayPause(indexPath)
            return
        }
        super.pressesEnded(presses, with: event)
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
///
/// The identifier API remembers the item, not its position: a refresh that inserts or removes items
/// before the focused one moves the position, and an index path would then point at a different
/// item. `TVScreenViewController` uses it; the index-path API stays for screens not yet migrated.
@MainActor
final class TVFocusMemory {
    private(set) var indexPath: IndexPath?
    private(set) var identifier: AnyHashable?

    func record(_ context: UICollectionViewFocusUpdateContext) {
        if let next = context.nextFocusedIndexPath {
            indexPath = next
        }
    }

    func record(_ context: UICollectionViewFocusUpdateContext, identifier: AnyHashable?) {
        guard let next = context.nextFocusedIndexPath else { return }
        indexPath = next
        self.identifier = identifier
    }

    /// The index path of the remembered item as `resolve` finds it now, or nil if it is gone.
    func preferredIndexPath(resolving resolve: (AnyHashable) -> IndexPath?) -> IndexPath? {
        identifier.flatMap(resolve)
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
        identifier = nil
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
