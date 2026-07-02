import UIKit

/// UI-only coordinator for native multi-selection on a `UICollectionView`: owns the editing state,
/// the Select/Done bar button, and the contextual bottom toolbar. It is deliberately ignorant of item
/// identity — the host view controller translates selected index paths into model objects and supplies
/// the toolbar actions. Works with the two-finger pan multi-select gesture when the host forwards
/// `shouldBeginMultipleSelectionInteractionAt` / `didBeginMultipleSelectionInteractionAt`.
@MainActor
final class MultiSelectController {
    private weak var collectionView: UICollectionView?
    private weak var host: UIViewController?

    /// Called after entering/exiting editing so the host can swap nav items and reconfigure cells.
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// Builds the bottom toolbar contents for the current selection count.
    var toolbarItemsProvider: ((Int) -> [UIBarButtonItem])?

    private(set) var isEditing = false
    let barButton = UIBarButtonItem()

    init(collectionView: UICollectionView, host: UIViewController) {
        self.collectionView = collectionView
        self.host = host
        collectionView.allowsMultipleSelectionDuringEditing = true
        configureBarButton(editing: false)
    }

    var selectedCount: Int { collectionView?.indexPathsForSelectedItems?.count ?? 0 }

    func setEditing(_ editing: Bool) {
        guard isEditing != editing, let collectionView, let host else { return }
        isEditing = editing
        collectionView.isEditing = editing
        if !editing {
            collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false) }
        }
        configureBarButton(editing: editing)
        host.tabBarController?.tabBar.isHidden = editing
        host.navigationController?.setToolbarHidden(!editing, animated: true)
        (editing ? onEnter : onExit)?()
        updateToolbar()
    }

    /// Host calls this from didSelect/didDeselect while editing so the toolbar reflects the count.
    func selectionChanged() { updateToolbar() }

    func selectAll(_ indexPaths: [IndexPath]) {
        guard let collectionView else { return }
        indexPaths.forEach { collectionView.selectItem(at: $0, animated: false, scrollPosition: []) }
        updateToolbar()
    }

    func deselectAll() {
        guard let collectionView else { return }
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false) }
        updateToolbar()
    }

    private func configureBarButton(editing: Bool) {
        barButton.primaryAction = UIAction(title: editing ? "Done" : "Select") { [weak self] _ in
            self?.setEditing(!editing)
        }
        barButton.style = editing ? .done : .plain
    }

    private func updateToolbar() {
        guard isEditing, let host else { return }
        host.setToolbarItems(toolbarItemsProvider?(selectedCount) ?? [], animated: false)
    }
}
