import CrucibleCore
import UIKit

/// One source's score on a detail page: the source's official mark, the score the way that source writes it, and its votes
/// or scale. Trakt's own tile carries an ember edge so the strip reads from it outwards.
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
        AppPlatform.isTV ? CGSize(width: 240, height: 184) : CGSize(width: 108, height: 90)
    }
}

package final class TraktScoreTileView: UIView, UIContentView {
    package var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let logoView = UIImageView()
    private let logoRow = UIView()
    private var logoWidth: NSLayoutConstraint?
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
        buildLogoRow()
        valueLabel.font = AppPlatform.isTV ? Theme.Font.title2 : Theme.Font.scaled(.title2, 22, .bold, maximum: 26)
        valueLabel.textColor = Theme.Color.label
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        detailLabel.font = AppPlatform.isTV ? Theme.Font.caption2Regular : Theme.Font.scaled(.caption2, 11, .regular, maximum: 13)
        detailLabel.textColor = Theme.Color.labelTertiary
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.7

        let stack = UIStackView(arrangedSubviews: [logoRow, valueLabel, detailLabel])
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

    /// The mark sits at the tile's leading edge at one height for every source; a wide wordmark shrinks to the tile's width.
    private func buildLogoRow() {
        logoView.contentMode = .scaleAspectFit
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoRow.addSubview(logoView)
        let width = logoView.widthAnchor.constraint(equalToConstant: Self.logoHeight)
        width.priority = UILayoutPriority(999)
        logoWidth = width
        NSLayoutConstraint.activate([
            logoRow.heightAnchor.constraint(equalToConstant: Self.logoHeight),
            logoView.leadingAnchor.constraint(equalTo: logoRow.leadingAnchor),
            logoView.topAnchor.constraint(equalTo: logoRow.topAnchor),
            logoView.bottomAnchor.constraint(equalTo: logoRow.bottomAnchor),
            logoView.trailingAnchor.constraint(lessThanOrEqualTo: logoRow.trailingAnchor),
            width,
        ])
    }

    private static var logoHeight: CGFloat { AppPlatform.isTV ? 36 : 20 }

    private func apply() {
        guard let configuration = configuration as? TraktScoreTileConfiguration else { return }
        let score = configuration.score
        let mark = BrandMark(score: score).image
        logoView.image = mark
        if let size = mark?.size, size.height > 0 { logoWidth?.constant = Self.logoHeight * size.width / size.height }
        valueLabel.text = TraktCopy.value(score)
        detailLabel.text = TraktCopy.detail(score)
        let highlighted = score.source == .trakt
        layer.borderColor = (highlighted ? Theme.Color.accent.withAlphaComponent(0.45) : Theme.Color.separator).cgColor
        accessibilityLabel = TraktCopy.accessibilityLabel(score)
        accessibilityTraits = score.link == nil ? .staticText : .link
    }
}
