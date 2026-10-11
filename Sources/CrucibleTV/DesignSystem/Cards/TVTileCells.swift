import CrucibleDesign
import UIKit

/// View data of a gradient tile: a genre in Browse Genres, or a library in the More tab.
struct TVTileItem: Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var symbol: String?
    var accessibilityHint: String?
    var gradient: TVTileGradient?

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        accessibilityHint: String? = nil,
        gradient: TVTileGradient? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accessibilityHint = accessibilityHint
        self.gradient = gradient
    }
}

/// Explicit tile colours (24-bit hex), for tiles whose palette is decided by shared logic instead of the name hash.
struct TVTileGradient: Hashable, Sendable {
    var top: UInt32
    var bottom: UInt32
}

enum TVTileStyle: Hashable, Sendable {
    case genre
    case library

    var size: CGSize {
        switch self {
        case .genre: TVMetrics.Card.genreSize
        case .library: TVMetrics.Card.libraryTileSize
        }
    }
}

/// Deterministic gradient palette: the same name always maps to the same tile colours.
enum TVTilePalette {
    private static let gradients: [(UInt32, UInt32)] = [
        (0x7A3B1F, 0x2B1208),
        (0x2E4F7A, 0x0F1D33),
        (0x5A2E73, 0x1D0F2B),
        (0x2F6B5C, 0x0C2A23),
        (0x8A2F3F, 0x2E0F16),
        (0x6B5A1F, 0x2A2308),
        (0x3F3F8A, 0x14143A),
        (0x1F6B7A, 0x0A2A33),
    ]

    static func colors(for name: String) -> (UIColor, UIColor) {
        let pair = gradients[Int(fnv1a(name) % UInt64(gradients.count))]
        return (UIColor(hex: pair.0), UIColor(hex: pair.1))
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

@MainActor
enum TVTileImage {
    private static var cache: [String: UIImage] = [:]

    static func gradient(name: String, size: CGSize, override: TVTileGradient? = nil) -> UIImage {
        let key = "\(name)|\(Int(size.width))x\(Int(size.height))|\(override.map { "\($0.top).\($0.bottom)" } ?? "")"
        if let cached = cache[key] { return cached }
        let (top, bottom) = override.map { (UIColor(hex: $0.top), UIColor(hex: $0.bottom)) } ?? TVTilePalette.colors(for: name)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) else { return }
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * 0.55, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        cache[key] = image
        return image
    }
}

struct TVTileConfiguration: UIContentConfiguration, Hashable {
    var item: TVTileItem
    var style: TVTileStyle

    func makeContentView() -> UIView & UIContentView {
        TVTileContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> TVTileConfiguration {
        self
    }
}

/// A gradient tile whose label rides on the artwork, so it lifts and tilts with the picture.
final class TVTileContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let style: TVTileStyle
    private let artwork = UIImageView()
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init(configuration: TVTileConfiguration) {
        self.configuration = configuration
        style = configuration.style
        super.init(frame: .zero)
        buildHierarchy()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHierarchy() {
        artwork.adjustsImageWhenAncestorFocused = true
        artwork.layer.cornerCurve = .continuous
        artwork.layer.cornerRadius = TVMetrics.Card.cornerRadius
        artwork.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artwork)

        symbolView.tintColor = Theme.Color.onArtSecondary
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        symbolView.contentMode = .scaleAspectFit
        titleLabel.font = Theme.Font.scaled(.headline, 38, .semibold, maximum: 48)
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = false
        subtitleLabel.font = TVCardTypography.subtitle
        subtitleLabel.textColor = Theme.Color.onArtSecondary

        let text = UIStackView(arrangedSubviews: [symbolView, UIView(), titleLabel, subtitleLabel])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = TVMetrics.Card.captionLabelSpacing
        text.setCustomSpacing(8, after: symbolView)
        text.insetsLayoutMarginsFromSafeArea = false
        text.isLayoutMarginsRelativeArrangement = true
        text.layoutMargins = UIEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        text.translatesAutoresizingMaskIntoConstraints = false
        artwork.overlayContentView.addSubview(text)

        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.widthAnchor.constraint(equalToConstant: style.size.width),
            artwork.heightAnchor.constraint(equalToConstant: style.size.height),
            text.topAnchor.constraint(equalTo: artwork.overlayContentView.topAnchor),
            text.leadingAnchor.constraint(equalTo: artwork.overlayContentView.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: artwork.overlayContentView.trailingAnchor),
            text.bottomAnchor.constraint(equalTo: artwork.overlayContentView.bottomAnchor),
        ])
    }

    private func apply() {
        guard let configuration = configuration as? TVTileConfiguration else { return }
        let item = configuration.item
        artwork.image = TVTileImage.gradient(name: item.title, size: style.size, override: item.gradient)
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        subtitleLabel.isHidden = (item.subtitle ?? "").isEmpty
        symbolView.image = item.symbol.flatMap { UIImage(systemName: $0) }
        symbolView.isHidden = item.symbol == nil
    }
}

class TVTileCell: UICollectionViewCell {
    class var style: TVTileStyle { .genre }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func registration<Cell: TVTileCell>(of type: Cell.Type) -> UICollectionView.CellRegistration<Cell, TVTileItem> {
        UICollectionView.CellRegistration<Cell, TVTileItem> { cell, _, item in
            cell.configure(with: item)
        }
    }

    func configure(with item: TVTileItem) {
        contentConfiguration = TVTileConfiguration(item: item, style: Self.style)
        accessibilityLabel = [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = item.accessibilityHint
    }
}

/// A genre tile for Browse Genres: a stable gradient with the genre name on it.
final class TVGenreCell: TVTileCell {
    override class var style: TVTileStyle { .genre }

    static func registration() -> UICollectionView.CellRegistration<TVGenreCell, TVTileItem> {
        registration(of: TVGenreCell.self)
    }
}

/// A library tile for the More tab: icon, library name and item count on a stable gradient.
final class TVLibraryTile: TVTileCell {
    override class var style: TVTileStyle { .library }

    static func registration() -> UICollectionView.CellRegistration<TVLibraryTile, TVTileItem> {
        registration(of: TVLibraryTile.self)
    }
}
