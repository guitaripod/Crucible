@preconcurrency import UIKit

struct StorageSummaryConfiguration: UIContentConfiguration {
    var storage: StorageSnapshot
    var isWiFiOnly: Bool
    var reclaimableBytes: Int64
    var onToggleWiFiOnly: (() -> Void)?
    var onFreeUp: ((UIView) -> Void)?

    func makeContentView() -> UIView & UIContentView {
        StorageSummaryView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> StorageSummaryConfiguration { self }
}

/// A button whose touch area is at least 44pt tall even when its visible chip is shorter.
final class HitTargetButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (Theme.Size.minTarget - bounds.width) / 2)
        let dy = max(0, (Theme.Size.minTarget - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

/// The 8pt segmented capacity bar: Crucible in ember, everything else on the volume in a high surface
/// and the remaining free space in a raised surface.
final class CapacityBarView: UIView {
    private let crucibleSegment = UIView()
    private let otherSegment = UIView()
    private let freeSegment = UIView()
    private var crucibleFraction: CGFloat = 0
    private var otherFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        clipsToBounds = true
        crucibleSegment.backgroundColor = Theme.Color.accent
        otherSegment.backgroundColor = Theme.Color.surfaceHigh
        freeSegment.backgroundColor = Theme.Color.surfaceRaised
        [crucibleSegment, otherSegment, freeSegment].forEach(addSubview)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 8)
    }

    func set(_ storage: StorageSnapshot) {
        guard storage.totalBytes > 0 else {
            crucibleFraction = 0
            otherFraction = 0
            setNeedsLayout()
            return
        }
        let total = Double(storage.totalBytes)
        let used = min(Double(storage.usedBytes), total)
        let other = max(0, total - Double(storage.freeBytes) - used)
        crucibleFraction = CGFloat(used / total)
        otherFraction = CGFloat(min(other, total - used) / total)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap: CGFloat = 2
        let crucibleVisible = crucibleFraction > 0
        let otherVisible = otherFraction > 0
        let gaps = CGFloat((crucibleVisible ? 1 : 0) + (otherVisible ? 1 : 0)) * gap
        let usable = max(0, bounds.width - gaps)
        let crucibleWidth = crucibleVisible ? max(4, usable * crucibleFraction) : 0
        let otherWidth = otherVisible ? min(usable - crucibleWidth, usable * otherFraction) : 0
        var x: CGFloat = 0
        crucibleSegment.isHidden = !crucibleVisible
        crucibleSegment.frame = CGRect(x: x, y: 0, width: crucibleWidth, height: bounds.height)
        x += crucibleWidth + (crucibleVisible ? gap : 0)
        otherSegment.isHidden = !otherVisible
        otherSegment.frame = CGRect(x: x, y: 0, width: max(0, otherWidth), height: bounds.height)
        x += max(0, otherWidth) + (otherVisible ? gap : 0)
        freeSegment.frame = CGRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height)
    }
}

final class StorageSummaryView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let usedLabel = UILabel()
    private let captionLabel = UILabel()
    private let freeLabel = UILabel()
    private let capacityBar = CapacityBarView()
    private let wifiChip = HitTargetButton()
    private let freeUpButton = HitTargetButton()
    private let headlineRow = UIStackView()
    private let valueStack = UIStackView()
    private let actionRow = UIStackView()
    private var onToggleWiFiOnly: (() -> Void)?
    private var onFreeUp: ((UIView) -> Void)?

    init(configuration: StorageSummaryConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        usedLabel.font = Theme.Font.title1
        usedLabel.textColor = Theme.Color.label
        captionLabel.text = "in Crucible"
        captionLabel.font = Theme.Font.footnote
        captionLabel.textColor = Theme.Color.labelSecondary
        freeLabel.font = Theme.Font.footnote
        freeLabel.textColor = Theme.Color.labelSecondary
        freeLabel.textAlignment = .right
        for label in [usedLabel, captionLabel, freeLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        freeLabel.setContentHuggingPriority(.required, for: .horizontal)
        usedLabel.setContentHuggingPriority(.required, for: .horizontal)

        valueStack.addArrangedSubview(usedLabel)
        valueStack.addArrangedSubview(captionLabel)
        valueStack.spacing = 8
        valueStack.alignment = .firstBaseline

        headlineRow.addArrangedSubview(valueStack)
        headlineRow.addArrangedSubview(UIView())
        headlineRow.addArrangedSubview(freeLabel)
        headlineRow.spacing = 8
        headlineRow.alignment = .firstBaseline

        wifiChip.addAction(UIAction { [weak self] _ in self?.onToggleWiFiOnly?() }, for: .primaryActionTriggered)
        freeUpButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onFreeUp?(self.freeUpButton)
        }, for: .primaryActionTriggered)
        wifiChip.setContentHuggingPriority(.required, for: .horizontal)
        freeUpButton.setContentHuggingPriority(.required, for: .horizontal)
        freeUpButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        actionRow.addArrangedSubview(wifiChip)
        actionRow.addArrangedSubview(UIView())
        actionRow.addArrangedSubview(freeUpButton)
        actionRow.spacing = 10
        actionRow.alignment = .center

        let root = UIStackView(arrangedSubviews: [headlineRow, capacityBar, actionRow])
        root.axis = .vertical
        root.spacing = 12
        root.setCustomSpacing(14, after: capacityBar)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            capacityBar.heightAnchor.constraint(equalToConstant: 8),
        ])

        applyContentSizeLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: StorageSummaryView, _: UITraitCollection) in
            view.applyContentSizeLayout()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StorageSummaryView, _: UITraitCollection) in
            view.apply()
        }
    }

    /// Stacks the headline and action rows vertically at accessibility text sizes so nothing truncates.
    private func applyContentSizeLayout() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        headlineRow.axis = large ? .vertical : .horizontal
        valueStack.axis = large ? .vertical : .horizontal
        actionRow.axis = large ? .vertical : .horizontal
        headlineRow.alignment = large ? .leading : .firstBaseline
        actionRow.alignment = large ? .leading : .center
        freeLabel.textAlignment = large ? .left : .right
    }

    private func apply() {
        guard let config = configuration as? StorageSummaryConfiguration else { return }
        onToggleWiFiOnly = config.onToggleWiFiOnly
        onFreeUp = config.onFreeUp

        usedLabel.text = Formatters.fileSize(config.storage.usedBytes)
        freeLabel.text = "\(Formatters.fileSize(config.storage.freeBytes)) free"
        capacityBar.set(config.storage)
        applyChip(isOn: config.isWiFiOnly)
        applyFreeUp(bytes: config.reclaimableBytes)
    }

    private func applyChip(isOn: Bool) {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.title = "Wi-Fi only"
        config.image = UIImage(systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        config.baseBackgroundColor = isOn ? Theme.Color.accentTint : Theme.Color.surfaceRaised
        config.baseForegroundColor = isOn ? Theme.Color.accentText : Theme.Color.label
        config.background.strokeColor = isOn ? Theme.Color.accentText : Theme.Color.separator
        config.background.strokeWidth = 1
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.subheadline, 14, .semibold)
            return outgoing
        }
        wifiChip.configuration = config
        wifiChip.accessibilityLabel = "Wi-Fi only"
        wifiChip.accessibilityValue = isOn ? "On" : "Off"
        wifiChip.accessibilityHint = "Double tap to change whether downloads may use cellular data"
    }

    private func applyFreeUp(bytes: Int64) {
        guard bytes > 0 else {
            freeUpButton.isHidden = true
            return
        }
        freeUpButton.isHidden = false
        var config = UIButton.Configuration.plain()
        config.title = "Free up \(Formatters.fileSize(bytes))"
        config.image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 0)
        config.baseForegroundColor = Theme.Color.accentText
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.subheadline, 14, .semibold)
            return outgoing
        }
        freeUpButton.configuration = config
        freeUpButton.accessibilityLabel = "Free up \(Formatters.fileSize(bytes)) by deleting watched downloads"
    }
}
