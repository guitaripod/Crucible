import CrucibleDesign
import UIKit

/// The large title at the top of a pushed library screen: one title2 line. The cell never takes focus.
@MainActor
enum TVScreenTitle {
    struct Content: Hashable {
        var title: String
    }

    /// Room kept above the title so it clears the floating tab bar (46 to 114pt).
    static let topInset: CGFloat = 130
    static let height: CGFloat = 100

    static func registration() -> UICollectionView.CellRegistration<UICollectionViewCell, Content> {
        UICollectionView.CellRegistration<UICollectionViewCell, Content> { cell, _, content in
            var configuration = UIListContentConfiguration.cell()
            configuration.text = content.title
            configuration.textProperties.font = Theme.Font.title2
            configuration.textProperties.color = Theme.Color.label
            configuration.directionalLayoutMargins = .zero
            configuration.axesPreservingSuperviewLayoutMargins = []
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = configuration
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = content.title
            cell.accessibilityTraits = .header
        }
    }

    static func section() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let section = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item]))
        section.contentInsets = NSDirectionalEdgeInsets(top: topInset, leading: 0, bottom: 0, trailing: 0)
        return section
    }
}
