import Foundation

/// The shape of a shared card: a 4:5 card for feeds, a 9:16 story, or a square.
package enum WatchCardFormat: String, CaseIterable, Sendable {
    case card, story, square

    package var title: String {
        switch self {
        case .card: return String(localized: "Card", comment: "Format of a shared watch card: the 4:5 image for feeds")
        case .story: return String(localized: "Story")
        case .square: return String(localized: "Square")
        }
    }

    /// The pixel size the image is shared at.
    package var pixelSize: (width: Int, height: Int) {
        switch self {
        case .card: return (1080, 1350)
        case .story: return (1080, 1920)
        case .square: return (1080, 1080)
        }
    }
}

/// The look of a shared card.
package enum WatchCardStyle: String, CaseIterable, Sendable {
    /// Colours taken from the title's own artwork.
    case artwork
    /// Crucible's warm black and ember.
    case ember
    /// Ink on cream, set like a page.
    case paper
    /// Black and white.
    case noir

    package var title: String {
        switch self {
        case .artwork: return String(localized: "Artwork", comment: "Look of a shared watch card whose colours come from the title's poster")
        case .ember: return String(localized: "Ember", comment: "Look of a shared watch card in Crucible's warm black and orange")
        case .paper: return String(localized: "Paper", comment: "Look of a shared watch card in dark ink on a cream page")
        case .noir: return String(localized: "Noir", comment: "Look of a shared watch card in black and white")
        }
    }
}

/// What the viewer chose for their cards, kept between cards so the next one starts the way the last one was shared.
package struct WatchCardOptions: Equatable, Sendable {
    package static let storageKey = "watchCard.options.v1"

    package var format: WatchCardFormat
    package var style: WatchCardStyle
    package var showsRating: Bool
    package var showsScores: Bool
    package var showsWatched: Bool
    package var showsDetails: Bool

    package init(
        format: WatchCardFormat = .card,
        style: WatchCardStyle = .artwork,
        showsRating: Bool = true,
        showsScores: Bool = true,
        showsWatched: Bool = true,
        showsDetails: Bool = true
    ) {
        self.format = format
        self.style = style
        self.showsRating = showsRating
        self.showsScores = showsScores
        self.showsWatched = showsWatched
        self.showsDetails = showsDetails
    }

    package static func saved(in defaults: UserDefaults = .standard) -> WatchCardOptions {
        guard let stored = defaults.dictionary(forKey: storageKey) else { return WatchCardOptions() }
        let fallback = WatchCardOptions()
        return WatchCardOptions(
            format: (stored["format"] as? String).flatMap(WatchCardFormat.init(rawValue:)) ?? fallback.format,
            style: (stored["style"] as? String).flatMap(WatchCardStyle.init(rawValue:)) ?? fallback.style,
            showsRating: stored["rating"] as? Bool ?? fallback.showsRating,
            showsScores: stored["scores"] as? Bool ?? fallback.showsScores,
            showsWatched: stored["watched"] as? Bool ?? fallback.showsWatched,
            showsDetails: stored["details"] as? Bool ?? fallback.showsDetails
        )
    }

    package func save(in defaults: UserDefaults = .standard) {
        defaults.set([
            "format": format.rawValue,
            "style": style.rawValue,
            "rating": showsRating,
            "scores": showsScores,
            "watched": showsWatched,
            "details": showsDetails,
        ], forKey: Self.storageKey)
    }
}
