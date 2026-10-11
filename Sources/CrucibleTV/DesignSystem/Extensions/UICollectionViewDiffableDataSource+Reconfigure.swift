import UIKit

extension UICollectionViewDiffableDataSource {
    /// Applies `snapshot` and reconfigures every item that was already on screen, so a changed
    /// value behind an unchanged identifier (a progress bar, a watched mark) is redrawn. Animation
    /// is requested per call and dropped under Reduce Motion.
    @MainActor
    func applyReconfiguringExisting(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>, animated: Bool = false) {
        var updated = snapshot
        let existing = Set(self.snapshot().itemIdentifiers)
        let survivors = snapshot.itemIdentifiers.filter { existing.contains($0) }
        updated.reconfigureItems(survivors)
        apply(updated, animatingDifferences: animated && TVMotion.animationsEnabled)
    }
}
