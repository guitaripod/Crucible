import Foundation

/// The meta line under a hero title: leading facts, an optional rating star, then trailing facts,
/// drawn as "2021 · 2 h 14 m · ★ 8.1 · 92% critics".
package struct DetailMeta: Equatable, Sendable {
    package let leading: [String]
    package let star: String?
    package let trailing: [String]

    package init(leading: [String], star: String?, trailing: [String]) {
        self.leading = leading
        self.star = star
        self.trailing = trailing
    }

    package var isEmpty: Bool {
        leading.isEmpty && star == nil && trailing.isEmpty
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
