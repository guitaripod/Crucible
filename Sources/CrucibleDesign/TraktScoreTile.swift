import CrucibleCore
import UIKit

/// One source's score on a detail page: the source's name, the score the way that source writes it, and its votes or
/// scale. Trakt's own tile carries an ember edge so the strip reads from it outwards.
package struct TraktScoreTileConfiguration: UIContentConfiguration, Hashable {
    package var score: TraktScore

    package init(score: TraktScore) {
        self.score = score
    }

    package func makeContentView() -> UIView & UIContentView {
        TraktScoreTileView(configuration: self)
    }

    package func updated(for state: UIConfigurationState) -> TraktScoreTileConfiguration {
        self
    }

    /// The tile's size on this platform; the strip lays tiles out at this size.
    package static var size: CGSize {
        AppPlatform.isTV ? CGSize(width: 240, height: 184) : CGSize(width: 108, height: 84)
    }
}

package final class TraktScoreTileView: UIView, UIContentView {
    package var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let sourceLabel = UILabel()
    private let valueLabel = UILabel()
    private let detailLabel = UILabel()

    package init(configuration: TraktScoreTileConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = Theme.Color.surface
        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous
        layer.borderWidth = AppPlatform.isTV ? 2 : 1
        sourceLabel.font = Theme.Font.badge
        sourceLabel.textColor = Theme.Color.labelTertiary
        sourceLabel.adjustsFontForContentSizeCategory = true
        sourceLabel.adjustsFontSizeToFitWidth = true
        sourceLabel.minimumScaleFactor = 0.7
        valueLabel.font = Theme.Font.title2
        valueLabel.textColor = Theme.Color.label
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        detailLabel.font = Theme.Font.caption2Regular
        detailLabel.textColor = Theme.Color.labelTertiary
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.7

        let stack = UIStackView(arrangedSubviews: [sourceLabel, valueLabel, detailLabel])
        stack.axis = .vertical
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset = AppPlatform.isTV ? Theme.Space.m : Theme.Space.s
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset * 0.75),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset * 0.75),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TraktScoreTileView, _: UITraitCollection) in
            view.apply()
        }
    }

    private func apply() {
        guard let configuration = configuration as? TraktScoreTileConfiguration else { return }
        let score = configuration.score
        sourceLabel.text = TraktCopy.sourceName(score.source).uppercased()
        valueLabel.text = TraktCopy.value(score)
        detailLabel.text = TraktCopy.detail(score)
        let highlighted = score.source == .trakt
        layer.borderColor = (highlighted ? Theme.Color.accent.withAlphaComponent(0.45) : Theme.Color.separator).cgColor
        accessibilityLabel = TraktCopy.accessibilityLabel(score)
        accessibilityTraits = score.link == nil ? .staticText : .link
    }
}
