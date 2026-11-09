import Foundation

/// The meta line under a hero title: leading facts, an optional rating star, then trailing facts,
/// drawn as "2021 · 2 h 14 m · ★ 8.1 · 92% critics".
package struct DetailMeta: Equatable, Sendable {
    package let leading: [String]
    package let ratings: [DetailRating]

    package init(leading: [String], ratings: [DetailRating]) {
        self.leading = leading
        self.ratings = ratings
    }

    package var isEmpty: Bool {
        leading.isEmpty && ratings.isEmpty
    }
}

/// One score on a detail page's meta line, beside the year and the runtime: drawn with its source's own mark when the source is
/// known (`score`), with Plex's star for a rating whose source the server does not name, or as plain words.
package struct DetailRating: Hashable, Sendable {
    package enum Mark: Hashable, Sendable {
        case star
        case score(TraktScore)
        case none
    }

    package let mark: Mark
    package let text: String
    package let spoken: String

    package init(mark: Mark, text: String, spoken: String) {
        self.mark = mark
        self.text = text
        self.spoken = spoken
    }

    /// A score from a known source, written and spoken the way that source writes it.
    package var scoreSource: TraktScore.Source? {
        if case .score(let score) = mark { return score.source }
        return nil
    }

    package init(score: TraktScore) {
        self.init(mark: .score(score), text: TraktCopy.value(score), spoken: "\(TraktCopy.sourceName(score.source)) \(TraktCopy.value(score))")
    }
}

/// The text of a detail hero: eyebrow, title, meta line, technical badges and the spoken summary.
package struct DetailHeroInfo: Equatable, Sendable {
    package let eyebrow: String
    package let title: String
    package let meta: DetailMeta
    package let badges: [String]
    package let accessibilityText: String
}

/// The image a detail hero draws behind its text; `isBackdrop` is false for portrait artwork that has to be framed.
package struct DetailArtwork: Equatable, Sendable {
    package let path: String?
    package let isBackdrop: Bool
}

/// One labelled row of the Details grid.
package struct DetailFact: Hashable, Sendable {
    package let key: String
    package let value: String

    package init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One audio or subtitle choice for a track menu.
package struct TrackOption: Equatable, Sendable {
    package let id: Int?
    package let title: String
    package let detail: String?
    package let isSelected: Bool
    package let isEnabled: Bool
}

/// The audio and subtitle tracks a detail screen has settled on.
package struct TrackSelection: Equatable, Sendable {
    package let audioId: Int?
    package let subtitleId: Int?
}
