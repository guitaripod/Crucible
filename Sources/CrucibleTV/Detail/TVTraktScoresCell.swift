import CrucibleCore
import CrucibleDesign
import UIKit

/// The ratings strip under a title's synopsis on Apple TV: one tile per source, read-only, so focus passes straight from
/// the synopsis to the action row. VoiceOver reads the whole strip as one element.
final class TVTraktScoresCell: UICollectionViewCell {
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = Theme.Space.s
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: TraktScoreTileConfiguration.size.height),
        ])
        isAccessibilityElement = true
        accessibilityIdentifier = "detail.traktScores"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    func configure(_ scores: [TraktScore]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for score in scores {
            let tile = TraktScoreTileView(configuration: TraktScoreTileConfiguration(score: score))
            tile.isAccessibilityElement = false
            tile.translatesAutoresizingMaskIntoConstraints = false
            let preferred = tile.widthAnchor.constraint(equalToConstant: TraktScoreTileConfiguration.size.width)
            preferred.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                preferred,
                tile.widthAnchor.constraint(lessThanOrEqualToConstant: TraktScoreTileConfiguration.size.width),
                tile.heightAnchor.constraint(equalToConstant: TraktScoreTileConfiguration.size.height),
            ])
            stack.addArrangedSubview(tile)
        }
        accessibilityLabel = ([TraktCopy.ratingsTitle] + scores.map(TraktCopy.accessibilityLabel)).joined(separator: ". ")
    }

    static func registration(scores: @escaping @MainActor () -> [TraktScore]) -> UICollectionView.CellRegistration<TVTraktScoresCell, Int> {
        UICollectionView.CellRegistration<TVTraktScoresCell, Int> { cell, _, _ in
            cell.configure(scores())
        }
    }
}
