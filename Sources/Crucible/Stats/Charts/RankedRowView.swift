import UIKit

/// A single ranked row: optional leading thumbnail, a title, a normalized horizontal bar, a
/// trailing value, and an optional trailing accessory (e.g. a completion ring). Used for Top Shows
/// and Top Genres.
final class RankedRowView: UIView {
    private let thumb = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let accessoryContainer = UIView()
    private var fillConstraint: NSLayoutConstraint?
    private var thumbWidthConstraint: NSLayoutConstraint!
    private var imageTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)

        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 6
        thumb.layer.cornerCurve = .continuous
        thumb.backgroundColor = StatsStyle.cardBackground
        thumb.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1

        valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .secondaryLabel
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        track.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.backgroundColor = StatsStyle.accent
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        let textStack = UIStackView(arrangedSubviews: [titleRow, track])
        textStack.axis = .vertical
        textStack.spacing = 8
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumb)
        addSubview(textStack)
        addSubview(accessoryContainer)

        thumbWidthConstraint = thumb.widthAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.heightAnchor.constraint(equalToConstant: 60),
            thumbWidthConstraint,

            textStack.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),

            accessoryContainer.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: 12),
            accessoryContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            accessoryContainer.centerYAnchor.constraint(equalTo: centerYAnchor),

            track.heightAnchor.constraint(equalToConstant: 6),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, valueText: String, fraction: Double, colorIndex: Int, thumbPath: String?, accessory: UIView? = nil) {
        titleLabel.text = title
        valueLabel.text = valueText
        fill.backgroundColor = StatsStyle.categoricalColor(colorIndex)

        let clamped = CGFloat(max(0.02, min(1, fraction)))
        fillConstraint?.isActive = false
        let constraint = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: clamped)
        constraint.isActive = true
        fillConstraint = constraint

        accessoryContainer.subviews.forEach { $0.removeFromSuperview() }
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessoryContainer.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
                accessory.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor),
                accessory.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
                accessory.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
                accessory.widthAnchor.constraint(equalToConstant: 34),
                accessory.heightAnchor.constraint(equalToConstant: 34),
            ])
        }

        imageTask?.cancel()
        thumb.image = nil
        if let thumbPath {
            thumbWidthConstraint.constant = 40
            thumb.isHidden = false
            imageTask = Task { [weak self] in
                let image = await ImageLoader.shared.loadImage(path: thumbPath, width: 120)
                guard !Task.isCancelled, let self else { return }
                self.thumb.image = image
            }
        } else {
            thumb.isHidden = true
            thumbWidthConstraint.constant = 0
        }
    }

    override func removeFromSuperview() {
        imageTask?.cancel()
        super.removeFromSuperview()
    }
}
