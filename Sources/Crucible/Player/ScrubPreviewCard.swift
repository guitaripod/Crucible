import CrucibleDesign
@preconcurrency import UIKit

/// The card that floats above the scrubber while the viewer scrubs: the picture at the moment under the finger or the
/// pointer on glass, with the time and the chapter beneath it. A title without stills gets the time and chapter alone, in
/// a glass capsule.
@MainActor
final class ScrubPreviewCard: UIView {
    private static let cornerRadius: CGFloat = 18
    private static let pictureInset: CGFloat = 5
    private static let widestAspect: CGFloat = 2.4
    private static let tallestAspect: CGFloat = 4.0 / 3.0

    private let glass = Glass.effectView(fallback: .systemThinMaterialDark)
    private let picture = UIImageView()
    private let timeLabel = UILabel()
    private let chapterLabel = UILabel()
    private let stack = UIStackView()
    private lazy var pictureWidth = picture.widthAnchor.constraint(equalToConstant: 200)
    private lazy var pictureHeight = picture.heightAnchor.constraint(equalToConstant: 112)
    private var margins: [NSLayoutConstraint] = []
    private var aspect: CGFloat = 16.0 / 9.0
    private var animator: UIViewPropertyAnimator?
    private(set) var isShown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        overrideUserInterfaceStyle = .dark
        alpha = 0

        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 26.0, *), Glass.isAvailable {
            glass.cornerConfiguration = .corners(radius: .fixed(Self.cornerRadius))
        } else {
            glass.layer.cornerRadius = Self.cornerRadius
            glass.layer.cornerCurve = .continuous
            glass.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
            glass.layer.borderColor = UIColor(white: 1, alpha: 0.16).cgColor
        }

        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.backgroundColor = UIColor(white: 0, alpha: 0.35)
        picture.layer.cornerRadius = Self.cornerRadius - Self.pictureInset
        picture.layer.cornerCurve = .continuous

        timeLabel.font = Theme.Font.scaled(.subheadline, .monospacedDigitSystemFont(ofSize: 15, weight: .semibold), maximum: 22)
        timeLabel.textColor = .white
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        chapterLabel.font = Theme.Font.scaled(.footnote, .systemFont(ofSize: 13, weight: .medium), maximum: 20)
        chapterLabel.textColor = UIColor(white: 1, alpha: 0.72)
        chapterLabel.lineBreakMode = .byTruncatingTail
        chapterLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let caption = UIStackView(arrangedSubviews: [timeLabel, chapterLabel])
        caption.axis = .horizontal
        caption.alignment = .firstBaseline
        caption.spacing = 6

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 5
        stack.addArrangedSubview(picture)
        stack.addArrangedSubview(caption)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glass)
        glass.contentView.addSubview(stack)
        margins = [
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            glass.contentView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            glass.contentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ]
        NSLayoutConstraint.activate(margins + [
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            pictureWidth,
            pictureHeight,
        ])
        layoutMargins(hasPicture: true)
    }

    /// Fills the card. `still` is nil while the picture for the moment is on its way; `hasPicture` is false for a title that
    /// has no stills at all, which collapses the card to its caption.
    func show(time: String, chapter: String?, still: UIImage?, hasPicture: Bool, pictureWidth width: CGFloat) {
        if timeLabel.text != time { timeLabel.text = time }
        if chapterLabel.text != chapter { chapterLabel.text = chapter }
        chapterLabel.isHidden = chapter?.isEmpty != false
        if picture.isHidden == hasPicture {
            picture.isHidden = !hasPicture
            layoutMargins(hasPicture: hasPicture)
        }
        guard hasPicture else { return }
        if let still, still !== picture.image {
            picture.image = still
            if still.size.height > 0 { aspect = min(max(still.size.width / still.size.height, Self.tallestAspect), Self.widestAspect) }
        }
        let height = (width / aspect).rounded()
        if pictureWidth.constant != width { pictureWidth.constant = width }
        if pictureHeight.constant != height { pictureHeight.constant = height }
    }

    /// A card with a picture hugs it; one without is a capsule around its caption.
    private func layoutMargins(hasPicture: Bool) {
        margins[0].constant = hasPicture ? Self.pictureInset : 8
        margins[1].constant = hasPicture ? Self.pictureInset : 14
        margins[2].constant = hasPicture ? Self.pictureInset : 14
        margins[3].constant = 8
    }

    /// Brings the card up out of the scrubber, or lets it sink back; a plain fade under Reduce Motion.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        animator?.stopAnimation(true)
        guard !UIAccessibility.isReduceMotionEnabled else {
            transform = .identity
            UIView.animate(withDuration: 0.15, delay: 0, options: .beginFromCurrentState) { self.alpha = shown ? 1 : 0 }
            return
        }
        let animator: UIViewPropertyAnimator
        if shown {
            if alpha == 0 { transform = Self.sunk(by: 0.8, height: bounds.height) }
            animator = UIViewPropertyAnimator(duration: 0.36, dampingRatio: 0.74) {
                self.alpha = 1
                self.transform = .identity
            }
        } else {
            let height = bounds.height
            animator = UIViewPropertyAnimator(duration: 0.16, curve: .easeIn) {
                self.alpha = 0
                self.transform = Self.sunk(by: 0.9, height: height)
            }
        }
        animator.startAnimation()
        self.animator = animator
    }

    /// The card scaled to `scale` about the middle of its bottom edge, where it meets the scrubber.
    private static func sunk(by scale: CGFloat, height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: height * (1 - scale) / 2).scaledBy(x: scale, y: scale)
    }
}
