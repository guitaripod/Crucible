import CrucibleCore
import CrucibleDesign
import UIKit

/// One half step of the star row: focus is the preview, Select rates.
@MainActor
private final class TVStarSegment: UIControl {
    static let starSide: CGFloat = 92
    static let height: CGFloat = 120

    let halfStars: Int
    private let glyph = UIImageView()
    private let marker = UIView()
    private var isFilled = false

    init(halfStars: Int) {
        self.halfStars = halfStars
        super.init(frame: .zero)
        let isLeadingHalf = halfStars % 2 == 1
        let clip = UIView()
        clip.clipsToBounds = true
        clip.isUserInteractionEnabled = false
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)

        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: Self.starSide * 0.9, weight: .regular)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(glyph)

        marker.backgroundColor = Theme.Color.accent
        marker.layer.cornerRadius = 3
        marker.alpha = 0
        marker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.starSide / 2),
            heightAnchor.constraint(equalToConstant: Self.height),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.heightAnchor.constraint(equalToConstant: Self.starSide),
            glyph.topAnchor.constraint(equalTo: clip.topAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Self.starSide),
            glyph.heightAnchor.constraint(equalToConstant: Self.starSide),
            isLeadingHalf ? glyph.leadingAnchor.constraint(equalTo: clip.leadingAnchor) : glyph.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            marker.centerXAnchor.constraint(equalTo: centerXAnchor),
            marker.widthAnchor.constraint(equalTo: widthAnchor, constant: -6),
            marker.heightAnchor.constraint(equalToConstant: 6),
            marker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = UserRating(halfStars: halfStars)?.spokenText
        accessibilityIdentifier = "rating.segment.\(halfStars)"
        setFilled(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { true }

    func setFilled(_ filled: Bool) {
        isFilled = filled
        glyph.image = UIImage(systemName: filled ? "star.fill" : "star")
        glyph.tintColor = filled ? Theme.Color.accent : Theme.Color.labelTertiary
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.contains(where: { $0.type == .select }) {
            sendActions(for: .primaryActionTriggered)
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.marker.alpha = focused ? 1 : 0 }
    }
}

/// Rates one title on Apple TV, in a glass panel over the dimmed screen: ten half-star steps that Swipe moves along and Select commits,
/// and Clear Rating for a title that has one. Menu closes it without a change.
@MainActor
final class TVRatingViewController: UIViewController {
    private static let starGap: CGFloat = 14

    private let titleText: String
    private let initial: UserRating?
    private let onSet: (UserRating?) -> Void
    private let panel = Glass.effectView(fallback: .regular)
    private let valueLabel = UILabel()
    private var segments: [TVStarSegment] = []
    private lazy var clearButton = TVButton.make(.glass, title: UserRatingCopy.clear, symbol: "star.slash") { [weak self] in
        self?.clear()
    }

    init(title: String, rating: UserRating?, onSet: @escaping (UserRating?) -> Void) {
        titleText = title
        initial = rating
        self.onSet = onSet
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas.withAlphaComponent(0.72)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = Theme.Radius.l
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        view.addSubview(panel)

        let heading = UILabel()
        heading.font = Theme.Font.title3
        heading.textColor = Theme.Color.label
        heading.text = titleText
        heading.textAlignment = .center
        heading.numberOfLines = 2
        heading.accessibilityTraits = .header

        valueLabel.font = Theme.Font.title2
        valueLabel.textColor = Theme.Color.label
        valueLabel.textAlignment = .center
        valueLabel.accessibilityIdentifier = "rating.value"

        let hint = UILabel()
        hint.font = Theme.Font.callout
        hint.textColor = Theme.Color.labelSecondary
        hint.textAlignment = .center
        hint.text = UserRatingCopy.tvHint

        let row = makeRow()
        clearButton.isHidden = initial == nil
        clearButton.accessibilityIdentifier = "rating.clear"

        let stack = UIStackView(arrangedSubviews: [heading, row, valueLabel, hint, clearButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.m
        stack.setCustomSpacing(Theme.Space.l, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stack)

        let inset = Theme.Space.xl
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 1000),
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -inset),
        ])
        preview(startingSegment.halfStars)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [startingSegment] }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let segment = context.nextFocusedView as? TVStarSegment {
            preview(segment.halfStars)
        }
    }

    /// The step focus starts on: the title's own rating, otherwise four stars, a place to move away from in either direction.
    private var startingSegment: TVStarSegment {
        let wanted = initial?.halfStars ?? 8
        return segments.first { $0.halfStars == wanted } ?? segments[0]
    }

    private func makeRow() -> UIStackView {
        segments = (1...UserRating.maxHalfStars).map { halfStars in
            let segment = TVStarSegment(halfStars: halfStars)
            segment.addAction(UIAction { [weak self] _ in self?.commit(halfStars) }, for: .primaryActionTriggered)
            return segment
        }
        let row = UIStackView(arrangedSubviews: segments)
        row.axis = .horizontal
        row.spacing = 0
        row.alignment = .top
        for segment in segments where segment.halfStars % 2 == 0 && segment.halfStars < UserRating.maxHalfStars {
            row.setCustomSpacing(Self.starGap, after: segment)
        }
        return row
    }

    private func preview(_ halfStars: Int) {
        for segment in segments {
            segment.setFilled(segment.halfStars <= halfStars)
        }
        let rating = UserRating(halfStars: halfStars)
        valueLabel.text = rating.map { "\($0.text) / \(UserRating.maxStars)" }
    }

    private func commit(_ halfStars: Int) {
        onSet(UserRating(halfStars: halfStars))
        dismiss(animated: TVMotion.animationsEnabled)
    }

    private func clear() {
        onSet(nil)
        dismiss(animated: TVMotion.animationsEnabled)
    }
}
