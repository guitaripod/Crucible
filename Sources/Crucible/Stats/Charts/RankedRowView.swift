import UIKit

/// A single ranked row: optional rank number, optional leading 36pt poster, a title with trailing
/// value, a 4pt bar normalised to the leader, and an optional trailing accessory (e.g. a completion
/// ring). Used for Top Shows and Top Genres; becomes a button when `onTap` is set.
final class RankedRowView: UIView {
    var onTap: (() -> Void)? {
        didSet {
            tapButton.isHidden = onTap == nil
            accessibilityElements = onTap == nil ? nil : [tapButton]
        }
    }

    private let rankLabel = UILabel()
    private let thumb = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let accessoryContainer = UIView()
    private let tapButton = UIButton(configuration: .plain())
    private var fillConstraint: NSLayoutConstraint?
    private var imageTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)

        rankLabel.font = Theme.Font.subheadlineSemibold
        rankLabel.adjustsFontForContentSizeCategory = true
        rankLabel.textColor = Theme.Color.labelTertiary
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)
        rankLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        rankLabel.isAccessibilityElement = false

        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = Theme.Radius.xs
        thumb.layer.cornerCurve = .continuous
        thumb.backgroundColor = StatsStyle.insetBackground
        thumb.setContentHuggingPriority(.required, for: .horizontal)
        thumb.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = Theme.Font.subheadlineSemibold
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2

        valueLabel.font = Theme.Font.scaled(.subheadline, 15, .medium)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = Theme.Color.labelSecondary
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        track.backgroundColor = StatsStyle.trackBackground
        track.layer.cornerRadius = 2
        track.clipsToBounds = true
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = StatsStyle.accent
        fill.layer.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        accessoryContainer.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        let textStack = UIStackView(arrangedSubviews: [titleRow, track])
        textStack.axis = .vertical
        textStack.spacing = 7

        let row = UIStackView(arrangedSubviews: [rankLabel, thumb, textStack, accessoryContainer])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        var buttonConfig = UIButton.Configuration.plain()
        buttonConfig.background.backgroundColor = .clear
        tapButton.configuration = buttonConfig
        tapButton.isHidden = true
        tapButton.translatesAutoresizingMaskIntoConstraints = false
        tapButton.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        addSubview(tapButton)

        thumb.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),

            thumb.widthAnchor.constraint(equalToConstant: 36),
            thumb.heightAnchor.constraint(equalToConstant: 54),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),

            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, valueText: String, fraction: Double, colorIndex: Int, thumbPath: String?, rank: Int? = nil, accessory: UIView? = nil) {
        titleLabel.text = title
        valueLabel.text = valueText
        fill.backgroundColor = StatsStyle.categoricalColor(colorIndex)
        tapButton.accessibilityLabel = [rank.map { "Number \($0)" }, title, valueText].compactMap { $0 }.joined(separator: ", ")

        rankLabel.isHidden = rank == nil
        rankLabel.text = rank.map(String.init)

        let clamped = CGFloat(max(0.02, min(1, fraction)))
        fillConstraint?.isActive = false
        let constraint = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: clamped)
        constraint.isActive = true
        fillConstraint = constraint

        accessoryContainer.subviews.forEach { $0.removeFromSuperview() }
        accessoryContainer.isHidden = accessory == nil
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessoryContainer.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
                accessory.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor),
                accessory.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
                accessory.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
                accessory.widthAnchor.constraint(equalToConstant: 30),
                accessory.heightAnchor.constraint(equalToConstant: 30),
            ])
        }

        imageTask?.cancel()
        thumb.image = nil
        thumb.isHidden = thumbPath == nil
        if let thumbPath {
            imageTask = Task { [weak self] in
                let image = await ImageLoader.shared.loadImage(path: thumbPath, width: 120)
                guard !Task.isCancelled, let self else { return }
                self.thumb.image = image
            }
        }
    }

    override func removeFromSuperview() {
        imageTask?.cancel()
        super.removeFromSuperview()
    }
}
