import CrucibleDesign
import UIKit

/// The shape of what a screen is loading, so the loading state can stand in its place instead of a bare spinner and dissolve into
/// the content when it arrives.
enum TVSkeletonLayout: Equatable {
    /// A pushed screen's title over rows of cards shaped like `style`, `columns` across, as a grid of titles lays them out.
    case grid(title: String, style: TVCardStyle, columns: Int)
    /// The rows of a list beside its context column, as the Settings-style screens lay them out; the column stays in view.
    case rows(count: Int)

    /// Whether the screen's context column stays up beside the skeleton.
    var keepsContext: Bool {
        if case .rows = self { return true }
        return false
    }

    @MainActor
    func makeView() -> UIView {
        switch self {
        case .grid(let title, let style, let columns): return TVSkeletonGridView(title: title, style: style, columns: columns)
        case .rows(let count): return TVSkeletonRowsView(count: count)
        }
    }

    @MainActor
    static func block(radius: CGFloat, color: UIColor = Theme.Color.surfaceRaised) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

/// A grid screen while its titles load: the real title, then two rows of cards with a caption line under each, pulsing softly
/// through `TVMotion` (not under Reduce Motion, the UI-test switch or while hidden). The title sits where the grid's header does,
/// clear of the tab bar from the top of the screen, because the grid does not inset its content by the safe area.
final class TVSkeletonGridView: TVPulsingView {
    private static let rows = 2
    private let cards = UIStackView()

    init(title: String, style: TVCardStyle, columns: Int) {
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Loading")
        accessibilityIdentifier = "grid.loading"

        let heading = TVScreenTitleView()
        heading.configure(TVScreenTitleContent(title: title))
        heading.isAccessibilityElement = false
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)

        cards.axis = .vertical
        cards.spacing = TVMetrics.gridRowSpacing
        cards.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cards)
        for _ in 0 ..< Self.rows {
            let row = UIStackView(arrangedSubviews: (0 ..< max(1, columns)).map { _ in Self.card(style) })
            row.axis = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = TVMetrics.gutter
            cards.addArrangedSubview(row)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor),
            heading.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            cards.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: TVMetrics.shelfTopInset),
            cards.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var pulsingLayer: CALayer { cards.layer }

    /// One card: artwork in the style's shape and a caption line under it.
    private static func card(_ style: TVCardStyle) -> UIView {
        let artwork = TVSkeletonLayout.block(radius: TVMetrics.Card.cornerRadius)
        let caption = TVSkeletonLayout.block(radius: Theme.Radius.xs)
        let card = UIView()
        card.addSubview(artwork)
        card.addSubview(caption)
        let aspect = style.artworkSize.height / max(style.artworkSize.width, 1)
        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: card.topAnchor),
            artwork.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor, multiplier: aspect),
            caption.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: TVMetrics.Card.captionSpacing),
            caption.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            caption.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.7),
            caption.heightAnchor.constraint(equalToConstant: 24),
            caption.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }
}

/// A Settings-style list while it loads: row plates with an icon well and two lines, where the rows will be, beside the screen's
/// context column. It pulses like every other skeleton.
final class TVSkeletonRowsView: TVPulsingView {
    private let rows = UIStackView()

    init(count: Int) {
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Loading")
        accessibilityIdentifier = "rows.loading"

        rows.axis = .vertical
        rows.spacing = TVMetrics.Row.spacing + Theme.Space.xs
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        for index in 0 ..< max(1, count) {
            rows.addArrangedSubview(Self.row(shortening: index))
        }
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: TVSettingsScaffold.Layout.contentTop),
            rows.leadingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.leadingAnchor,
                constant: TVSettingsScaffold.Layout.contextWidth + TVSettingsScaffold.Layout.columnGap
            ),
            rows.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var pulsingLayer: CALayer { rows.layer }

    /// A row plate whose lines get a little shorter row by row, so the list reads as text rather than as stripes.
    private static func row(shortening index: Int) -> UIView {
        let plate = TVSkeletonLayout.block(radius: Theme.Radius.m)
        let well = TVSkeletonLayout.block(radius: Theme.Radius.s, color: Theme.Color.surfaceHigh)
        let title = TVSkeletonLayout.block(radius: Theme.Radius.xs, color: Theme.Color.surfaceHigh)
        let detail = TVSkeletonLayout.block(radius: Theme.Radius.xs, color: Theme.Color.surfaceHigh)
        [well, title, detail].forEach(plate.addSubview)
        let widths: [CGFloat] = [0.62, 0.48, 0.7, 0.4, 0.55, 0.66]
        let width = widths[index % widths.count]
        NSLayoutConstraint.activate([
            plate.heightAnchor.constraint(equalToConstant: TVMetrics.Row.height + Theme.Space.l),
            well.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: TVMetrics.Row.horizontalInset),
            well.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            well.heightAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            title.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: Theme.Space.m),
            title.bottomAnchor.constraint(equalTo: plate.centerYAnchor, constant: -Theme.Space.xxs),
            title.heightAnchor.constraint(equalToConstant: 24),
            title.widthAnchor.constraint(equalTo: plate.widthAnchor, multiplier: width * 0.6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: plate.centerYAnchor, constant: Theme.Space.xs),
            detail.heightAnchor.constraint(equalToConstant: 20),
            detail.widthAnchor.constraint(equalTo: plate.widthAnchor, multiplier: width),
        ])
        return plate
    }
}
