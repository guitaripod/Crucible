import CrucibleCore
import CrucibleDesign
import UIKit

/// The left side of the paywall: the name, why the screen opened, what Pro includes on Apple TV and the legal pages as plain
/// text. Nothing in it is focusable; each block is a `TVReadOnlyPanel`, so VoiceOver reaches it as one stop.
final class TVPaywallInfoColumn: UIStackView {
    private static let wellSide: CGFloat = TVMetrics.Row.iconWell

    init(request: PaywallRequest, features: [ProFeature] = ProFeature.listed(isTV: true)) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .fill
        spacing = Theme.Space.l
        addArrangedSubview(Self.headerPanel(reason: ProTVPresentation.reasonLine(for: request.feature)))
        addArrangedSubview(Self.featuresPanel(features))
        addArrangedSubview(Self.legalPanel())
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    private static func headerPanel(reason: String?) -> UIView {
        let title = UILabel()
        title.text = "Crucible Pro"
        title.font = Theme.Font.largeTitle
        title.textColor = Theme.Color.label
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7

        let stack = UIStackView(arrangedSubviews: [title])
        stack.axis = .vertical
        stack.spacing = Theme.Space.xs
        if let reason {
            let label = UILabel()
            label.text = reason
            label.font = TVFont.control
            label.textColor = Theme.Color.accentText
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
        let panel = TVReadOnlyPanel(wrapping: stack) {
            ["Crucible Pro", reason].compactMap { $0 }.joined(separator: ". ")
        }
        panel.accessibilityTraits = .header
        panel.accessibilityIdentifier = "paywall.header"
        return panel
    }

    private static func featuresPanel(_ features: [ProFeature]) -> UIView {
        let stack = UIStackView(arrangedSubviews: features.map(featureRow))
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        let panel = TVReadOnlyPanel(wrapping: stack) {
            "Includes. " + features.map { "\($0.title). \($0.summary)" }.joined(separator: " ")
        }
        panel.accessibilityIdentifier = "paywall.features"
        return panel
    }

    private static func featureRow(_ feature: ProFeature) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: feature.symbol))
        icon.contentMode = .center
        icon.tintColor = Theme.Color.accentText
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.row, weight: .semibold)
        let well = UIView()
        well.backgroundColor = Theme.Color.accentTint
        well.layer.cornerRadius = Theme.Radius.s
        well.layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)

        let title = UILabel()
        title.text = feature.title
        title.font = TVFont.cardTitle
        title.textColor = Theme.Color.label
        let summary = UILabel()
        summary.text = feature.summary
        summary.font = TVFont.cardSubtitle
        summary.textColor = Theme.Color.labelSecondary
        summary.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [title, summary])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs

        let row = UIStackView(arrangedSubviews: [well, text])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Space.s
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: wellSide),
            well.heightAnchor.constraint(equalToConstant: wellSide),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        return row
    }

    /// The Terms of Use and Privacy Policy addresses as text, for the paywall and the Pro screen.
    static func legalPanel() -> UIView {
        let label = UILabel()
        label.text = ProTVPresentation.legalDisplayText
        label.font = Theme.Font.footnote
        label.textColor = Theme.Color.labelSecondary
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        let panel = TVReadOnlyPanel(wrapping: label) { ProTVPresentation.legalText }
        panel.accessibilityIdentifier = "paywall.legal"
        return panel
    }
}
