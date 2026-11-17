import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The loading state of a title page, in the page's own shape: the artwork's place, the title over its bottom edge, the buttons, the
/// synopsis, then the cast for a film or an episode, or the seasons and their episodes for a show. It stands in until the page's first
/// answer and then dissolves into it (`revealLoadedPage`).
struct DetailSkeletonConfiguration: SkeletonConfiguration, Hashable {
    enum Shape: Hashable {
        case title
        case show
    }

    var shape: Shape
    /// The artwork's height as a share of a phone's width, as the page's `DetailHeroCoordinator` has it.
    var heroRatio: CGFloat

    func makeContentView() -> UIView & UIContentView {
        DetailSkeletonContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailSkeletonConfiguration {
        self
    }
}

private final class DetailSkeletonContentView: SkeletonCanvasView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { setNeedsLayout() }
    }

    private var shape: DetailSkeletonConfiguration { configuration as? DetailSkeletonConfiguration ?? DetailSkeletonConfiguration(shape: .title, heroRatio: 1.28) }
    private let column = UIView()
    private var heroHeight: NSLayoutConstraint?
    private var columnLeading: NSLayoutConstraint?
    private var columnWidth: NSLayoutConstraint?

    init(configuration: DetailSkeletonConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        let artwork = artworkArea()
        addSubview(artwork)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let titleBlock = makeTitleBlock()
        let body = configuration.shape == .show ? makeShowBody() : makeTitleBody()
        [titleBlock, body].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview($0)
        }

        let heroHeight = artwork.heightAnchor.constraint(equalToConstant: 0)
        let columnLeading = column.leadingAnchor.constraint(equalTo: leadingAnchor)
        let columnWidth = column.widthAnchor.constraint(equalToConstant: 0)
        self.heroHeight = heroHeight
        self.columnLeading = columnLeading
        self.columnWidth = columnWidth
        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: trailingAnchor),
            heroHeight,
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            columnLeading,
            columnWidth,
            titleBlock.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            titleBlock.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            titleBlock.bottomAnchor.constraint(equalTo: artwork.bottomAnchor, constant: -Theme.Space.l),
            body.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: Theme.Space.m),
            body.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Follows the page's own measurements: the artwork's rest height for this size, and the column a row's content keeps to.
    override func layoutSubviews() {
        let size = bounds.size
        heroHeight?.constant = DetailHeroCoordinator.restHeight(for: size, heightRatio: shape.heroRatio)
        let room = Theme.Room(width: size.width, height: size.height)
        let width = room == .compact ? size.width - Theme.Space.m * 2 : min(size.width - room.gutter * 2, Theme.readableWidth)
        columnLeading?.constant = room == .compact ? Theme.Space.m : room.gutter
        columnWidth?.constant = max(0, width)
        super.layoutSubviews()
    }

    /// The eyebrow, the title and the line of facts that sit over the artwork's bottom edge.
    private func makeTitleBlock() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(makeBlock(width: 92, height: 12, cornerRadius: 4))
        addLine(0.66, to: stack, height: 30, cornerRadius: 8)
        addLine(0.5, to: stack, height: 14)
        return stack
    }

    /// Play beside the round buttons, then the synopsis.
    private func makeLead() -> UIStackView {
        let actions = UIStackView(arrangedSubviews: [makeBlock(width: 150, height: 50, cornerRadius: 25)])
        actions.spacing = Theme.Space.s
        for _ in 0..<3 { actions.addArrangedSubview(makeBlock(width: 50, height: 50, cornerRadius: 25)) }

        let lead = UIStackView()
        lead.axis = .vertical
        lead.alignment = .leading
        lead.spacing = 9
        let actionsRow = clipped(actions, in: lead)
        lead.setCustomSpacing(Theme.Space.l, after: actionsRow)
        for share in [1.0, 0.94, 0.6] {
            addLine(share, to: lead, height: 13)
        }
        return lead
    }

    /// Adds `row` to `stack` inside a strip as wide as the column, so a row longer than a narrow window runs off its edge instead of
    /// squeezing.
    @discardableResult
    private func clipped(_ row: UIView, in stack: UIStackView) -> UIView {
        let strip = UIView()
        strip.clipsToBounds = true
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)
        stack.addArrangedSubview(strip)
        NSLayoutConstraint.activate([
            strip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.topAnchor.constraint(equalTo: strip.topAnchor),
            row.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
        ])
        return strip
    }

    private func makeTitleBody() -> UIView {
        let body = makeLead()
        let header = makeBlock(width: 118, height: 18, cornerRadius: 5)
        body.setCustomSpacing(Theme.Space.xl, after: body.arrangedSubviews.last ?? body)
        body.addArrangedSubview(header)
        body.setCustomSpacing(Theme.Space.s, after: header)
        let cast = UIStackView()
        cast.spacing = 14
        cast.alignment = .center
        for _ in 0..<6 {
            let person = UIStackView(arrangedSubviews: [makeBlock(width: 64, height: 64, cornerRadius: 32), makeBlock(width: 52, height: 10, cornerRadius: 4)])
            person.axis = .vertical
            person.alignment = .center
            person.spacing = 8
            cast.addArrangedSubview(person)
        }
        clipped(cast, in: body)
        return body
    }

    private func makeShowBody() -> UIView {
        let body = makeLead()
        let seasons = UIStackView()
        seasons.spacing = Theme.Space.xs
        for _ in 0..<3 { seasons.addArrangedSubview(makeBlock(width: 96, height: 34, cornerRadius: 17)) }
        body.setCustomSpacing(Theme.Space.xl, after: body.arrangedSubviews.last ?? body)
        let strip = clipped(seasons, in: body)
        body.setCustomSpacing(Theme.Space.m, after: strip)
        for index in 0..<3 {
            let episode = makeEpisodeRow()
            body.addArrangedSubview(episode)
            episode.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            if index < 2 { body.setCustomSpacing(Theme.Space.m, after: episode) }
        }
        return body
    }

    private func makeEpisodeRow() -> UIView {
        let text = UIStackView()
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 8
        addLine(0.7, to: text, height: 14)
        addLine(0.95, to: text, height: 11)
        addLine(0.55, to: text, height: 11)
        let row = UIStackView(arrangedSubviews: [makeBlock(width: 128, height: 72, cornerRadius: 10), text])
        row.spacing = Theme.Space.s
        row.alignment = .center
        return row
    }
}

extension UICollectionViewController {
    /// Puts a title page's skeleton up while nothing has loaded.
    func showDetailSkeleton(_ shape: DetailSkeletonConfiguration.Shape, heroRatio: CGFloat) {
        contentUnavailableConfiguration = DetailSkeletonConfiguration(shape: shape, heroRatio: heroRatio)
    }

    /// The failure of a page that has nothing to show yet, with Retry.
    func showDetailLoadError(title: String, message: String, retry: @escaping () -> Void) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = title
        config.secondaryText = message
        var button = UIButton.Configuration.filled()
        button.title = String(localized: "Retry")
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        button.cornerStyle = .capsule
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.contentUnavailableConfiguration = nil
            retry()
        }
        contentUnavailableConfiguration = config
    }
}
