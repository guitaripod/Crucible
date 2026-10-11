import CrucibleDesign
import CrucibleStats
import UIKit

/// A horizontally scrollable strip of "binge" cards, one per ``BingeSession``, where each
/// capsule's width encodes how many episodes were watched in the session. Feed it via
/// ``setSessions(_:)`` with the sessions already sorted biggest-first.
package final class BingeTimelineView: UIView {
    private let metrics: StatsMetrics.BingeTimeline
    private let horizontalInset: CGFloat = 0

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

    package init(metrics: StatsMetrics = .platform) {
        self.metrics = metrics.bingeTimeline
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BingeTimelineView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics.intrinsicHeight)
    }

    /// Replaces the strip's content and, unless Reduce Motion is on, springs the new cards in.
    package func setSessions(_ sessions: [BingeSession]) {
        self.sessions = sessions
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = sessions.enumerated().map { index, session in
            let card = BingeCardView(session: session, colorIndex: index, metrics: metrics)
            scrollView.addSubview(card)
            return card
        }
        pendingEntrance = !cardViews.isEmpty
        scrollView.contentOffset = .zero
        setNeedsLayout()
        setNeedsDisplay()
    }

    package override func layoutSubviews() {
        super.layoutSubviews()

        let scrollHeight = max(0, bounds.height - metrics.topInset - metrics.axisReserve)
        scrollView.frame = CGRect(x: 0, y: metrics.topInset, width: bounds.width, height: scrollHeight)

        var x = horizontalInset
        for card in cardViews {
            let width = cardWidth(for: card.episodeCount)
            let rect = CGRect(x: x, y: 0, width: width, height: scrollHeight)
            card.bounds = CGRect(origin: .zero, size: rect.size)
            card.center = CGPoint(x: rect.midX, y: rect.midY)
            x += width + metrics.cardSpacing
        }

        let contentWidth = cardViews.isEmpty ? 0 : x - metrics.cardSpacing + horizontalInset
        scrollView.contentSize = CGSize(width: max(0, contentWidth), height: scrollHeight)

        if pendingEntrance, scrollHeight > 0, bounds.width > 0 {
            pendingEntrance = false
            runEntranceAnimation()
        }
    }

    package override func draw(_ rect: CGRect) {
        guard !cardViews.isEmpty, bounds.width > horizontalInset * 2 else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let y = (bounds.height - metrics.axisBottomMargin).rounded() - 0.5
        ctx.setStrokeColor(axisColor.resolvedColor(with: traitCollection).cgColor)
        ctx.setLineWidth(metrics.axisLineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: horizontalInset, y: y))
        ctx.addLine(to: CGPoint(x: bounds.width - horizontalInset, y: y))
        ctx.strokePath()
    }

    private func cardWidth(for episodeCount: Int) -> CGFloat {
        BingeCardView.width(forEpisodes: episodeCount, metrics: metrics)
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

/// One binge capsule: show title, episode count and when it ended, on a categorical colour. Its width
/// encodes the episode count (``width(forEpisodes:metrics:)``).
package final class BingeCardView: UIView {
    let episodeCount: Int

    private let titleLabel = UILabel()
    private let epsLabel = UILabel()
    private let captionLabel = UILabel()
    private let contentStack = UIStackView()
    private let metrics: StatsMetrics.BingeTimeline

    package convenience init(session: BingeSession, colorIndex: Int, metrics: StatsMetrics = .platform) {
        self.init(session: session, colorIndex: colorIndex, metrics: metrics.bingeTimeline)
    }

    init(session: BingeSession, colorIndex: Int, metrics: StatsMetrics.BingeTimeline) {
        self.episodeCount = session.episodeCount
        self.metrics = metrics
        super.init(frame: .zero)

        backgroundColor = StatsStyle.categoricalColor(colorIndex).withAlphaComponent(0.9)
        layer.cornerRadius = StatsStyle.tileCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = metrics.cardShadowRadius
        layer.shadowOffset = CGSize(width: 0, height: metrics.cardShadowOffset)

        configureLabels(with: session)
        assembleStack()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    package static func width(forEpisodes episodeCount: Int, metrics: StatsMetrics = .platform) -> CGFloat {
        width(forEpisodes: episodeCount, metrics: metrics.bingeTimeline)
    }

    fileprivate static func width(forEpisodes episodeCount: Int, metrics: StatsMetrics.BingeTimeline) -> CGFloat {
        let raw = CGFloat(max(0, episodeCount)) * metrics.pointsPerEpisode
        return min(metrics.maxCardWidth, max(metrics.minCardWidth, raw))
    }

    package override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func configureLabels(with session: BingeSession) {
        titleLabel.font = metrics.titleFont.uiFont
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        epsLabel.font = metrics.episodesFont.uiFont
        epsLabel.textColor = Theme.Color.onArt
        epsLabel.numberOfLines = 1
        epsLabel.lineBreakMode = .byTruncatingTail

        captionLabel.font = metrics.captionFont.uiFont
        captionLabel.textColor = Theme.Color.onArtSecondary
        captionLabel.numberOfLines = 1
        captionLabel.lineBreakMode = .byTruncatingTail

        titleLabel.text = session.showTitle
        let epsText = episodeCount == 1 ? "1 ep" : "\(episodeCount) eps"
        epsLabel.text = epsText
        let captionText = session.endedCaption ?? ""
        captionLabel.text = captionText
        captionLabel.isHidden = captionText.isEmpty

        for label in [titleLabel, epsLabel, captionLabel] {
            label.shadowColor = UIColor.black.withAlphaComponent(metrics.labelShadowOpacity)
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
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = metrics.cardStackSpacing
        contentStack.addArrangedSubview(titleLabel)
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        contentStack.addArrangedSubview(spacer)
        contentStack.addArrangedSubview(epsLabel)
        contentStack.addArrangedSubview(captionLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.cardInsetHorizontal),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.cardInsetHorizontal),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: metrics.cardInsetVertical),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -metrics.cardInsetVertical),
        ])
    }
}
