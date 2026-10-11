import CrucibleDesign
import UIKit

/// What the hero block shows: the focused item's eyebrow, title, facts, badges, synopsis and progress.
struct TVHeroInfo: Equatable, Sendable {
    var eyebrow: String?
    var title: String
    var metaParts: [String]
    var badges: [String]
    var synopsis: String?
    var progress: Double?

    init(
        eyebrow: String? = nil,
        title: String,
        metaParts: [String] = [],
        badges: [String] = [],
        synopsis: String? = nil,
        progress: Double? = nil
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.metaParts = metaParts
        self.badges = badges
        self.synopsis = synopsis
        self.progress = progress
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        eyebrowLabel.font = Theme.Font.caption1
        eyebrowLabel.textColor = Theme.Color.accentText
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = TVMetrics.Hero.titleLines
        titleLabel.accessibilityTraits = .header
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
        isAccessibilityElement = false
        accessibilityElements = [eyebrowLabel, titleLabel, metaLabel, synopsisLabel]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
