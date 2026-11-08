import CrucibleCore
import UIKit

/// The official marks of the services Crucible works with, drawn from each brand's own artwork (`tools/brand`), for the
/// ratings strip and the rows that open an integration.
package enum BrandMark: String, CaseIterable, Sendable, Hashable {
    case trakt
    case imdb
    case tmdb
    case rottenTomatoesFresh = "rottentomatoes-fresh"
    case rottenTomatoesRotten = "rottentomatoes-rotten"
    case metacritic
    case letterboxd
    case myAnimeList = "myanimelist"
    case seerr

    /// The mark, resolved for light and dark where the brand draws it differently.
    @MainActor
    package var image: UIImage? {
        BrandMarkStore.shared.image(for: self)
    }

    /// Whether the mark spells the name out, so a label beside it would only repeat it.
    package var isWordmark: Bool {
        switch self {
        case .imdb, .tmdb, .myAnimeList: return true
        default: return false
        }
    }

    /// The mark for a library's rating source, where one is drawn small enough for a menu.
    package init?(source: RatingSource) {
        switch source {
        case .rottenTomatoesCritics, .rottenTomatoesAudience: self = .rottenTomatoesFresh
        case .imdb: self = .imdb
        case .tmdb: return nil
        }
    }

    /// The mark fitted to a menu row's image size, drawn in its own colours.
    @MainActor
    package var menuImage: UIImage? {
        guard let image else { return nil }
        let height: CGFloat = 18
        let width = min(40, height * image.size.width / max(image.size.height, 1))
        let size = CGSize(width: width, height: height)
        let fitted = UIGraphicsImageRenderer(size: size).image { _ in
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        return fitted.withRenderingMode(.alwaysOriginal)
    }

    /// The mark for a score: Rotten Tomatoes shows its rotten splat below 60%, as it does on its own site.
    package init(score: TraktScore) {
        switch score.source {
        case .trakt: self = .trakt
        case .imdb: self = .imdb
        case .tmdb: self = .tmdb
        case .rottenTomatoes: self = score.value >= 60 ? .rottenTomatoesFresh : .rottenTomatoesRotten
        case .metascore: self = .metacritic
        case .letterboxd: self = .letterboxd
        case .myAnimeList: self = .myAnimeList
        }
    }
}

/// Loads each mark once from the design bundle and keeps it for the life of the app.
@MainActor
private final class BrandMarkStore {
    static let shared = BrandMarkStore()
    private var images: [BrandMark: UIImage] = [:]

    func image(for mark: BrandMark) -> UIImage? {
        if let cached = images[mark] { return cached }
        let image: UIImage?
        if mark == .letterboxd {
            image = Self.adaptive(light: Self.load("letterboxd-light"), dark: Self.load("letterboxd-dark"))
        } else {
            image = Self.load(mark.rawValue)
        }
        images[mark] = image
        return image
    }

    private static func load(_ name: String) -> UIImage? {
        UIImage(named: "brand-\(name)", in: .module, compatibleWith: nil)
    }

    /// One image that UIKit resolves per appearance: Letterboxd's overlapping dots are white on dark and slate on light.
    private static func adaptive(light: UIImage?, dark: UIImage?) -> UIImage? {
        guard let light, let dark else { return light ?? dark }
        let asset = UIImageAsset()
        asset.register(light, with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(dark, with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection.current)
    }
}
