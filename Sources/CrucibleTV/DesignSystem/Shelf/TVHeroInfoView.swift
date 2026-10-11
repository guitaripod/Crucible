import CrucibleDesign
import UIKit

/// What the hero block shows: the focused item's eyebrow, title, facts, badges, synopsis and progress.
struct TVHeroInfo: Equatable, Sendable {
    enum TitleStyle: Sendable {
        case title2
        case title1
    }

    var eyebrow: String?
    var title: String
    var metaParts: [String]
    var badges: [String]
    var synopsis: String?
    var progress: Double?
    var titleStyle: TitleStyle
    var accessibilityText: String?

    /// `accessibilityText` is what VoiceOver reads for the whole block; when nil it is built from
    /// the visible fields (title, eyebrow, facts, badges, synopsis).
    init(
        eyebrow: String? = nil,
        title: String,
        metaParts: [String] = [],
        badges: [String] = [],
        synopsis: String? = nil,
        progress: Double? = nil,
        titleStyle: TitleStyle = .title2,
        accessibilityText: String? = nil
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.metaParts = metaParts
        self.badges = badges
        self.synopsis = synopsis
        self.progress = progress
        self.titleStyle = titleStyle
        self.accessibilityText = accessibilityText
    }

    var spokenText: String {
        if let accessibilityText, !accessibilityText.isEmpty { return accessibilityText }
        let facts = metaParts.filter { !$0.isEmpty }.joined(separator: ", ")
        let badgeText = badges.isEmpty ? nil : badges.joined(separator: ", ")
        return [title, eyebrow, facts, badgeText, synopsis].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    var spokenProgress: String? {
        guard let progress, progress > 0, progress < 1 else { return nil }
        return "\(Int((progress * 100).rounded())) percent watched"
    }
}

/// The text block over a backdrop (Home hero, movie, episode and show detail): eyebrow, title,
/// middle-dot meta line, badges, synopsis and an optional thin progress bar. Colours are semantic,
/// so it reads on the canvas-tinted scrim in both Dark and Light.
final class TVHeroInfoView: UIView {
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let badgeContainer = UIView()
    private let synopsisLabel = UILabel()
    private let progressBar = ProgressBar()
    private let stack = UIStackView()
    private var badgeRow: UIStackView?
    private var currentInfo: TVHeroInfo?
    private var adaptedHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        eyebrowLabel.font = Theme.Font.caption1
        eyebrowLabel.textColor = Theme.Color.accentText
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = TVMetrics.Hero.titleLines
        metaLabel.font = Theme.Font.callout
        metaLabel.textColor = Theme.Color.labelSecondary
        metaLabel.numberOfLines = 1
        synopsisLabel.font = Theme.Font.body
        synopsisLabel.textColor = Theme.Color.labelSecondary
        synopsisLabel.numberOfLines = TVMetrics.Hero.synopsisLines
        progressBar.style = .onArt
        progressBar.heightAnchor.constraint(equalToConstant: Theme.Metric.progressBarThickness).isActive = true

        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = TVMetrics.Hero.blockSpacing
        [eyebrowLabel, titleLabel, metaLabel, badgeContainer, synopsisLabel, progressBar].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(TVMetrics.Hero.blockSpacing + 6, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let width = stack.widthAnchor.constraint(equalToConstant: TVMetrics.Hero.textColumnWidth)
        width.priority = UILayoutPriority(900)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            width,
            progressBar.widthAnchor.constraint(equalToConstant: 420),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height > 0, bounds.height != adaptedHeight else { return }
        adaptedHeight = bounds.height
        adaptLines()
    }

    /// Replaces the shown info; `animated` cross-dissolves the text (instant under Reduce Motion).
    func configure(_ info: TVHeroInfo?, animated: Bool = false) {
        guard info != currentInfo else { return }
        currentInfo = info
        let update = { self.apply(info) }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            update()
            return
        }
        UIView.transition(with: self, duration: TVMetrics.Duration.heroText, options: [.transitionCrossDissolve, .allowUserInteraction], animations: update)
    }

    private func apply(_ info: TVHeroInfo?) {
        isHidden = info == nil
        guard let info else { return }
        titleLabel.font = info.titleStyle == .title1 ? Theme.Font.title1 : Theme.Font.title2
        accessibilityLabel = info.spokenText
        accessibilityValue = info.spokenProgress
        eyebrowLabel.text = info.eyebrow?.uppercased()
        eyebrowLabel.isHidden = (info.eyebrow ?? "").isEmpty
        titleLabel.text = info.title
        let meta = info.metaParts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        metaLabel.text = meta
        metaLabel.isHidden = meta.isEmpty
        synopsisLabel.text = info.synopsis
        synopsisLabel.isHidden = (info.synopsis ?? "").isEmpty
        let showsProgress = (info.progress ?? 0) > 0 && (info.progress ?? 0) < 1
        progressBar.isHidden = !showsProgress
        if let progress = info.progress, showsProgress { progressBar.progress = progress }
        replaceBadges(info.badges)
        adaptedHeight = 0
        setNeedsLayout()
    }

    /// The block has a fixed height, so a long title plus a long synopsis must give way rather than
    /// overflow into the shelf below: the synopsis loses lines first (3, 2, 1), then the title drops
    /// to one line, then the synopsis goes. Everything else keeps its size.
    private func adaptLines() {
        synopsisLabel.numberOfLines = TVMetrics.Hero.synopsisLines
        titleLabel.numberOfLines = TVMetrics.Hero.titleLines
        synopsisLabel.isHidden = (currentInfo?.synopsis ?? "").isEmpty
        while contentHeight() > bounds.height + 0.5 {
            if synopsisLabel.numberOfLines > 1 {
                synopsisLabel.numberOfLines -= 1
            } else if titleLabel.numberOfLines > 1 {
                titleLabel.numberOfLines -= 1
            } else if !synopsisLabel.isHidden {
                synopsisLabel.isHidden = true
            } else {
                break
            }
        }
    }

    private func contentHeight() -> CGFloat {
        let width = min(bounds.width, TVMetrics.Hero.textColumnWidth)
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        return stack.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    private func replaceBadges(_ badges: [String]) {
        badgeRow?.removeFromSuperview()
        badgeRow = nil
        badgeContainer.isHidden = badges.isEmpty
        guard !badges.isEmpty else { return }
        let row = BadgeChipView.row(badges)
        row.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: badgeContainer.topAnchor),
            row.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor),
            row.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.trailingAnchor),
        ])
        badgeRow = row
    }
}

/// Collection cell that hosts the hero block as section 0 of a screen. It never takes focus, so the
/// remote moves straight from the tab bar to the first shelf.
final class TVHeroCell: UICollectionViewCell {
    let infoView = TVHeroInfoView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        infoView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(infoView)
        NSLayoutConstraint.activate([
            infoView.topAnchor.constraint(equalTo: contentView.topAnchor),
            infoView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -TVMetrics.Hero.bottomClearance),
            infoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            infoView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    /// The hero is one stable item per screen; `configure` runs on every dequeue so the cell always
    /// shows the screen's current info, and the screen updates `infoView` directly as focus moves.
    static func registration(configure: @escaping @MainActor (TVHeroInfoView) -> Void) -> UICollectionView.CellRegistration<TVHeroCell, Int> {
        UICollectionView.CellRegistration<TVHeroCell, Int> { cell, _, _ in
            configure(cell.infoView)
        }
    }
}
