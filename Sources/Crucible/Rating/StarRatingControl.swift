import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Five stars the viewer taps or drags across: the left half of a star is its half step, the right half its whole one.
/// `.valueChanged` fires on every step under the finger, `.primaryActionTriggered` once when the finger lifts.
final class StarRatingControl: UIControl {
    private static let adjustableCommitDelay: Duration = .milliseconds(700)

    private let starSize: CGFloat
    private let starSpacing: CGFloat
    private(set) var rating: UserRating?
    private let stars = (0..<UserRating.maxStars).map { _ in UIImageView() }
    private let row = UIStackView()
    private var commitTask: Task<Void, Never>?

    init(starSize: CGFloat = 40, starSpacing: CGFloat = 8) {
        self.starSize = starSize
        self.starSpacing = starSpacing
        super.init(frame: .zero)
        row.axis = .horizontal
        row.spacing = starSpacing
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        for star in stars {
            star.contentMode = .center
            star.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: starSize, weight: .regular)
            row.addArrangedSubview(star)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: starSize + 12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = UserRatingCopy.title
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { commitTask?.cancel() }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(UserRating.maxStars)
        return CGSize(width: count * starSize + (count - 1) * starSpacing, height: starSize + 12)
    }

    /// A sideways drag that starts on the stars picks a rating, so it never opens a list row's swipe actions; an upward or
    /// downward one still scrolls whatever the stars sit in.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view !== self else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) >= abs(velocity.x)
    }

    func setRating(_ newValue: UserRating?, animated: Bool = false) {
        guard newValue != rating else { return }
        rating = newValue
        render(animated: animated)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        commitTask?.cancel()
        preview(at: touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        preview(at: touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { preview(at: touch.location(in: self)) }
        sendActions(for: .primaryActionTriggered)
    }

    private func preview(at point: CGPoint) {
        guard row.bounds.width > 0 else { return }
        let fraction = Double((point.x - row.frame.minX) / row.bounds.width)
        guard let next = UserRating(fraction: fraction), next != rating else { return }
        rating = next
        Haptics.selection()
        render()
        sendActions(for: .valueChanged)
    }

    override func accessibilityIncrement() {
        adjust(by: 1)
    }

    override func accessibilityDecrement() {
        adjust(by: -1)
    }

    private func adjust(by halfSteps: Int) {
        let next = rating.map { $0.stepped(by: halfSteps) } ?? UserRating(halfStars: max(1, halfSteps))
        guard next != nil, next != rating else { return }
        rating = next
        render()
        sendActions(for: .valueChanged)
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.adjustableCommitDelay)
            guard !Task.isCancelled else { return }
            self?.sendActions(for: .primaryActionTriggered)
        }
    }

    private func render(animated: Bool = false) {
        let update = {
            for (index, star) in self.stars.enumerated() {
                let position = (index + 1) * 2
                let halfStars = self.rating?.halfStars ?? 0
                let filled = halfStars >= position
                let half = halfStars == position - 1
                star.image = UIImage(systemName: filled ? "star.fill" : (half ? "star.leadinghalf.filled" : "star"))
                star.tintColor = filled || half ? Theme.Color.accent : Theme.Color.labelTertiary
            }
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self, duration: 0.15, options: .transitionCrossDissolve, animations: update)
        } else {
            update()
        }
        accessibilityValue = rating?.spokenText ?? String(localized: "Not rated", comment: "Accessibility value of the star rating control when the title has no rating")
    }
}
