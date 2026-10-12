import CrucibleDesign
import UIKit

/// The paywall's one status line: what the store is doing (waiting for the App Store, restoring) and how an attempt ended
/// (pending approval, nothing to restore, a failure), on a rounded plate. It keeps its height when empty so the plans below
/// do not jump when a message comes and goes, and it is a focus stop for VoiceOver only while it has something to say.
final class TVPaywallStatusPanel: TVReadOnlyPanel {
    private static let minimumHeight: CGFloat = 76

    private let plate = UIView()
    private let row = TVStatusRow()
    private var text = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.backgroundColor = Theme.Color.surfaceRaised
        plate.layer.cornerRadius = Theme.Radius.m
        plate.layer.cornerCurve = .continuous
        plate.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(row)
        contentView.addSubview(plate)
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            plate.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
            row.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -Theme.Space.m),
            row.topAnchor.constraint(greaterThanOrEqualTo: plate.topAnchor, constant: Theme.Space.xs),
            row.bottomAnchor.constraint(lessThanOrEqualTo: plate.bottomAnchor, constant: -Theme.Space.xs),
            row.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        spokenLabel = { [weak self] in self?.text }
        accessibilityIdentifier = "paywall.status"
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { !text.isEmpty && super.canBecomeFocused }

    /// Shows `text` (an empty plate for nil), with a spinner while `isBusy`.
    func show(_ text: String?, isBusy: Bool = false, tone: TVStatusRow.Tone = .neutral) {
        self.text = text ?? ""
        row.show(text, isBusy: isBusy, tone: tone)
        plate.alpha = self.text.isEmpty ? 0 : 1
        isAccessibilityElement = !self.text.isEmpty
    }
}
