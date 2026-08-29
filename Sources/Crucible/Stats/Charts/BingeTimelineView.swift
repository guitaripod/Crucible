import UIKit

/// A horizontally scrollable strip of "binge" cards, one per ``BingeSession``, where each
/// capsule's width encodes how many episodes were watched in the session. Feed it via
/// ``setSessions(_:)`` with the sessions already sorted biggest-first.
final class BingeTimelineView: UIView {
    private enum Metrics {
        static let intrinsicHeight: CGFloat = 120
        static let topInset: CGFloat = 4
        static let axisReserve: CGFloat = 16
        static let axisBottomMargin: CGFloat = 8
        static let horizontalInset: CGFloat = 12
        static let cardSpacing: CGFloat = 12
        static let minCardWidth: CGFloat = 64
        static let maxCardWidth: CGFloat = 220
        static let pointsPerEpisode: CGFloat = 10
    }

    private let scrollView: UIScrollView = {
        let view = UIScrollView()
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.alwaysBounceHorizontal = true
        view.clipsToBounds = true
        view.backgroundColor = .clear
        return view
    }()

    private let axisColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.14)
            : UIColor.black.withAlphaComponent(0.12)
    }

    private var sessions: [BingeSession] = []
    private var cardViews: [BingeCardView] = []
    private var pendingEntrance = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BingeTimelineView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.intrinsicHeight)
    }

    /// Replaces the strip's content and, unless Reduce Motion is on, springs the new cards in.
    func setSessions(_ sessions: [BingeSession]) {
        self.sessions = sessions
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = sessions.enumerated().map { index, session in
            let card = BingeCardView(session: session, colorIndex: index)
            scrollView.addSubview(card)
            return card
        }
        pendingEntrance = !cardViews.isEmpty
        scrollView.contentOffset = .zero
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let scrollHeight = max(0, bounds.height - Metrics.topInset - Metrics.axisReserve)
        scrollView.frame = CGRect(x: 0, y: Metrics.topInset, width: bounds.width, height: scrollHeight)

        var x = Metrics.horizontalInset
        for card in cardViews {
            let width = cardWidth(for: card.episodeCount)
            let rect = CGRect(x: x, y: 0, width: width, height: scrollHeight)
            card.bounds = CGRect(origin: .zero, size: rect.size)
            card.center = CGPoint(x: rect.midX, y: rect.midY)
            x += width + Metrics.cardSpacing
        }

        let contentWidth = cardViews.isEmpty ? 0 : x - Metrics.cardSpacing + Metrics.horizontalInset
        scrollView.contentSize = CGSize(width: max(0, contentWidth), height: scrollHeight)

        if pendingEntrance, scrollHeight > 0, bounds.width > 0 {
            pendingEntrance = false
            runEntranceAnimation()
        }
    }

    override func draw(_ rect: CGRect) {
        guard !cardViews.isEmpty, bounds.width > Metrics.horizontalInset * 2 else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let y = (bounds.height - Metrics.axisBottomMargin).rounded() - 0.5
        ctx.setStrokeColor(axisColor.resolvedColor(with: traitCollection).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: Metrics.horizontalInset, y: y))
        ctx.addLine(to: CGPoint(x: bounds.width - Metrics.horizontalInset, y: y))
        ctx.strokePath()
    }

    private func cardWidth(for episodeCount: Int) -> CGFloat {
        let raw = CGFloat(max(0, episodeCount)) * Metrics.pointsPerEpisode
        return min(Metrics.maxCardWidth, max(Metrics.minCardWidth, raw))
    }

    private func runEntranceAnimation() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            cardViews.forEach { $0.alpha = 1; $0.transform = .identity }
            return
        }
        for (index, card) in cardViews.enumerated() {
            card.alpha = 0
            card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            let delay = min(Double(index) * 0.05, 0.4)
            UIView.animate(
                withDuration: 0.5,
                delay: delay,
                usingSpringWithDamping: 0.82,
                initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                card.alpha = 1
                card.transform = .identity
            }
        }
    }
}

private final class BingeCardView: UIView {
    let episodeCount: Int

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let epsLabel: UILabel = {
        let label = UILabel()
        label.font = BingeCardView.roundedFont(size: 20, weight: .bold)
        label.textColor = .white
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let captionLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.82)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }()

    init(session: BingeSession, colorIndex: Int) {
        self.episodeCount = session.episodeCount
        super.init(frame: .zero)

        backgroundColor = StatsStyle.categoricalColor(colorIndex).withAlphaComponent(0.9)
        layer.cornerRadius = StatsStyle.tileCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        configureLabels(with: session)
        assembleStack()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func configureLabels(with session: BingeSession) {
        titleLabel.text = session.showTitle
        let epsText = episodeCount == 1 ? "1 ep" : "\(episodeCount) eps"
        epsLabel.text = epsText
        let captionText = Formatters.unixRelativeDate(session.endViewedAt) ?? ""
        captionLabel.text = captionText
        captionLabel.isHidden = captionText.isEmpty

        for label in [titleLabel, epsLabel, captionLabel] {
            label.shadowColor = UIColor.black.withAlphaComponent(0.25)
            label.shadowOffset = CGSize(width: 0, height: 1)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = [session.showTitle, epsText, captionText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func assembleStack() {
        contentStack.addArrangedSubview(titleLabel)
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        contentStack.addArrangedSubview(spacer)
        contentStack.addArrangedSubview(epsLabel)
        contentStack.addArrangedSubview(captionLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
