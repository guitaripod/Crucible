import CrucibleCore
import UIKit

/// A poster from Plex by its library path, with a quiet symbol until it arrives or when there is none.
package final class SportsPosterView: UIView {
    private let imageView = UIImageView()
    private let placeholder = UIImageView(image: UIImage(systemName: "sportscourt"))
    private let gradient = CAGradientLayer()
    private let eyebrowLabel = UILabel()
    private let captionLabel = UILabel()
    private var task: Task<Void, Never>?
    private var shownPath: String?
    private var shownWidth: CGFloat = 0

    override package init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = Theme.Radius.s
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.artHairline.cgColor
        clipsToBounds = true
        gradient.colors = [Theme.Color.emberTop.cgColor, Theme.Color.emberMid.cgColor, Theme.Color.emberBottom.cgColor]
        gradient.locations = [0, 0.55, 1]
        layer.insertSublayer(gradient, at: 0)
        placeholder.tintColor = Theme.Color.emberEyebrow.withAlphaComponent(0.85)
        placeholder.contentMode = .scaleAspectFit
        eyebrowLabel.textColor = Theme.Color.emberEyebrow
        eyebrowLabel.numberOfLines = 2
        eyebrowLabel.adjustsFontSizeToFitWidth = true
        eyebrowLabel.minimumScaleFactor = 0.7
        captionLabel.textColor = .white
        captionLabel.numberOfLines = 4
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.6
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        let words = UIStackView(arrangedSubviews: [eyebrowLabel, captionLabel])
        words.axis = .vertical
        words.spacing = 4
        for view in [placeholder, words, imageView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            words.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            words.topAnchor.constraint(greaterThanOrEqualTo: placeholder.bottomAnchor, constant: 6),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { task?.cancel() }

    override package func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        let width = max(bounds.width, 40)
        eyebrowLabel.font = .systemFont(ofSize: max(8, width * 0.075), weight: .heavy)
        captionLabel.font = .systemFont(ofSize: max(11, width * 0.13), weight: .bold)
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: max(16, width * 0.19))
        placeholder.isHidden = imageView.image != nil
    }

    /// Shows the poster at `path` (a Plex library path), loading it at `width` points, and again when it is later shown
    /// much wider; until it arrives, or when there is none, an ember poster with `words` on it, or the court symbol alone.
    package func show(path: String?, width: CGFloat, words: SportsPosterWords? = nil) {
        eyebrowLabel.text = words?.eyebrow.uppercased(with: .current)
        captionLabel.text = words?.caption
        eyebrowLabel.isHidden = words == nil || width < 70
        captionLabel.isHidden = words == nil || width < 70
        let sharper = path == shownPath && width > shownWidth * 1.25
        guard path != shownPath || sharper else { return }
        shownPath = path
        shownWidth = width
        task?.cancel()
        if !sharper {
            imageView.image = nil
            placeholder.isHidden = false
        }
        guard let path else { return }
        let pixels = Int(width * UIScreen.main.scale)
        task = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: pixels)
            guard !Task.isCancelled, let self, let image else { return }
            UIView.transition(with: imageView, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, options: .transitionCrossDissolve) {
                self.imageView.image = image
            }
            placeholder.isHidden = true
        }
    }
}

/// A file name becoming its title: the release name in small monospaced type, an arrow, and the clean title. It can play
/// the change once, which is the whole feature in one gesture.
package final class SportsTransformView: UIView {
    private let fileLabel = UILabel()
    private let arrow = UIImageView(image: UIImage(systemName: "arrow.down"))
    private let titleLabel = UILabel()
    private let stack = UIStackView()

    override package init(frame: CGRect) {
        super.init(frame: frame)
        fileLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        fileLabel.adjustsFontForContentSizeCategory = true
        fileLabel.textColor = Theme.Color.labelTertiary
        fileLabel.numberOfLines = 2
        fileLabel.lineBreakMode = .byTruncatingMiddle
        arrow.tintColor = Theme.Color.accentText
        arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .medium)
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 3
        [fileLabel, arrow, titleLabel].forEach(stack.addArrangedSubview)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `file` becoming `title`; `fileFont` replaces the small monospaced type, and `centered` centres all three lines.
    package func show(file: String, title: String, titleFont: UIFont, fileFont: UIFont? = nil, centered: Bool = false) {
        if let fileFont {
            fileLabel.font = fileFont
            arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: fileFont, scale: .medium)
        }
        stack.alignment = centered ? .center : .leading
        fileLabel.textAlignment = centered ? .center : .natural
        titleLabel.textAlignment = centered ? .center : .natural
        fileLabel.text = file
        titleLabel.text = title
        titleLabel.font = titleFont
        accessibilityLabel = SportsCopy.becomes(file, title)
    }

    /// Plays the change: the file name steps back and the title arrives. With Reduce Motion it is a short crossfade.
    package func play() {
        if UIAccessibility.isReduceMotionEnabled {
            titleLabel.alpha = 0
            UIView.animate(withDuration: 0.2) { self.titleLabel.alpha = 1 }
            return
        }
        fileLabel.alpha = 1
        fileLabel.transform = .identity
        arrow.alpha = 0
        arrow.transform = CGAffineTransform(translationX: 0, y: -6)
        titleLabel.alpha = 0
        titleLabel.transform = CGAffineTransform(scaleX: 0.96, y: 0.96).translatedBy(x: 0, y: 6)
        UIView.animate(withDuration: 0.35, delay: 0.15, options: .curveEaseOut) {
            self.fileLabel.alpha = 0.7
        }
        UIView.animate(withDuration: 0.3, delay: 0.3, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.arrow.alpha = 1
            self.arrow.transform = .identity
        }
        UIView.animate(withDuration: 0.5, delay: 0.45, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.titleLabel.alpha = 1
            self.titleLabel.transform = .identity
        }
    }
}
