import Foundation

/// The chapters a player offers: only for a file with more than one, in order, and the one the playhead is in.
package enum ChapterList {
    package static let title = String(localized: "Chapters", comment: "Player menu listing the title's chapters")

    package static func playable(_ chapters: [PlexChapter]) -> [PlexChapter] {
        let sorted = chapters.sorted { $0.startSecs < $1.startSecs }
        return sorted.count > 1 ? sorted : []
    }

    /// The chapter `position` (seconds on the title's own timeline) falls in.
    package static func current(_ chapters: [PlexChapter], at position: Double) -> PlexChapter? {
        chapters.last { $0.startSecs <= position + 0.5 }
    }

    /// "12:34 · Night Shift", the line a chapter menu shows.
    package static func menuTitle(_ chapter: PlexChapter) -> String {
        "\(Formatters.timestamp(chapter.startSecs)) · \(chapter.title)"
    }
}
