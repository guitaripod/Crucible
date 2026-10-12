import CrucibleCore
import CrucibleDesign
import UIKit

/// The message under the close button: a pending approval, nothing to restore, or a failed purchase. It stays until it is
/// dismissed or replaced, so a slow reader or a VoiceOver user never loses it.
final class PaywallNoticeBannerView: UIView {
    var onDismiss: (() -> Void)?

    private let icon = UIImageView()
    private let label = UILabel()
    private let dismissButton = UIButton(configuration: .plain())
    private var tone = Theme.Color.labelSecondary

    override init(frame: CGRect) {
        super.init(frame: frame)

        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = Theme.Font.subheadline
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        config.baseForegroundColor = Theme.Color.labelSecondary
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        dismissButton.configuration = config
        dismissButton.accessibilityLabel = "Dismiss message"
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [icon, label, dismissButton])
        row.alignment = .center
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            dismissButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget),
            dismissButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget),
        ])

        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        backgroundColor = Theme.Color.surface
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (banner: PaywallNoticeBannerView, _: UITraitCollection) in
            banner.applyBorder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ notice: PaywallModel.Notice) {
        let message = PaywallModel.message(for: notice)
        label.text = message
        label.accessibilityLabel = message
        switch notice {
        case .pending:
            icon.image = Self.symbol("clock.fill")
            tone = Theme.Color.accent
        case .nothingToRestore:
            icon.image = Self.symbol("info.circle.fill")
            tone = Theme.Color.labelSecondary
        case .failure:
            icon.image = Self.symbol("exclamationmark.triangle.fill")
            tone = Theme.Color.destructive
        }
        icon.tintColor = tone
        applyBorder()
    }

    private func applyBorder() {
        layer.borderColor = tone.resolvedColor(with: traitCollection).withAlphaComponent(0.55).cgColor
    }

    private static func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
    }
}
