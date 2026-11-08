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
