import UIKit

/// View data for every card in the family. Screens map their Plex models onto it; the cells never
/// see a model, so the same card works for movies, episodes, people, genres and libraries.
struct TVCardItem: Hashable, Sendable {
    var id: String
    var artworkPath: String?
    var title: String
    var subtitle: String?
    var detail: String?
    var eyebrow: String?
    var progress: Double?
    var isUnwatched = false
    var isWatched = false
    var isDimmed = false
    var badgeText: String?
    var placeholderSymbol = "film"
    var accessibilityHint: String?
    var highlight: String?

    init(
        id: String,
        artworkPath: String? = nil,
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        eyebrow: String? = nil,
        progress: Double? = nil,
        isUnwatched: Bool = false,
        isWatched: Bool = false,
        isDimmed: Bool = false,
        badgeText: String? = nil,
        placeholderSymbol: String = "film",
        accessibilityHint: String? = nil,
        highlight: String? = nil
    ) {
        self.id = id
        self.artworkPath = artworkPath
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.eyebrow = eyebrow
        self.progress = progress
        self.isUnwatched = isUnwatched
        self.isWatched = isWatched
        self.isDimmed = isDimmed
        self.badgeText = badgeText
        self.placeholderSymbol = placeholderSymbol
        self.accessibilityHint = accessibilityHint
        self.highlight = highlight
    }

    var hasProgress: Bool { (progress ?? 0) > 0 && (progress ?? 0) < 1 }

    var spokenLabel: String {
        [eyebrow, title, subtitle, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var spokenValue: String? {
        if hasProgress, let progress { return "\(Int((progress * 100).rounded())) percent watched" }
        if isWatched { return "Watched" }
        if isUnwatched { return "Unwatched" }
        return nil
    }
}
