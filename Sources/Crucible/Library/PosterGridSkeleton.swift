import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The loading state of a poster grid (a filmography, a collection, a playlist): as many rows of cards, each with its caption, as fill
/// the window at the grid's own column count and artwork shape, under the skeleton's sweeping light.
struct PosterGridSkeletonConfiguration: SkeletonConfiguration, Hashable {
    /// Height over width of the grid's artwork.
    var aspect: CGFloat

    func makeContentView() -> UIView & UIContentView {
        PosterGridSkeletonContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> PosterGridSkeletonConfiguration {
        self
    }
}

private final class PosterGridSkeletonContentView: SkeletonCanvasView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { setNeedsLayout() }
    }

    private let grid = UIStackView()
    private var builtFor: (columns: Int, rows: Int, aspect: CGFloat)?

    init(configuration: PosterGridSkeletonConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        backgroundColor = .clear
        grid.axis = .vertical
        grid.spacing = Theme.Space.s + 2
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: Theme.Space.s),
            grid.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Theme.Space.m),
            grid.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Space.m),
        ])
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        rebuildIfNeeded()
        super.layoutSubviews()
    }

    /// Lays the cards out again when the window's width changes the column count or its height the rows that fit.
    private func rebuildIfNeeded() {
        let aspect = (configuration as? PosterGridSkeletonConfiguration)?.aspect ?? Theme.Size.posterAspect
        let width = bounds.width - safeAreaInsets.left - safeAreaInsets.right - Theme.Space.m * 2
        guard width > 0 else { return }
        let columns = Theme.gridColumns(forWidth: bounds.width, aspect: aspect)
        let cardWidth = (width - 10 * CGFloat(columns - 1)) / CGFloat(columns)
        let rowHeight = cardWidth * aspect + Theme.Size.captionBlockHeight + grid.spacing
        let rows = max(1, Int(ceil((bounds.height - safeAreaInsets.top) / max(rowHeight, 1))))
        if let builtFor, builtFor.columns == columns, builtFor.rows == rows, builtFor.aspect == aspect { return }
        builtFor = (columns, rows, aspect)
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        forgetBlocks()
        for _ in 0..<rows {
            let row = UIStackView()
            row.spacing = 10
            row.distribution = .fillEqually
            row.alignment = .top
            for _ in 0..<columns { row.addArrangedSubview(makeCard(aspect: aspect)) }
            grid.addArrangedSubview(row)
        }
    }

    private func makeCard(aspect: CGFloat) -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.alignment = .leading
        card.spacing = 7
        let artwork = makeBlock(cornerRadius: Theme.Radius.s)
        card.addArrangedSubview(artwork)
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalTo: card.widthAnchor),
            artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor, multiplier: aspect),
        ])
        card.setCustomSpacing(Theme.Space.xs + 2, after: artwork)
        addLine(0.82, to: card, height: 11)
        addLine(0.5, to: card, height: 9)
        return card
    }
}
