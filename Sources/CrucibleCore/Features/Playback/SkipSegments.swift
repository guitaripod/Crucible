import Foundation

/// The skippable stretches of one item: Plex's own intro and credits markers first, then what the
/// file's chapter names say. Many anime and TV releases name their chapters ("Opening Theme",
/// "Recap", "Next Episode Preview"), which is the only place a recap or a preview is ever marked.
package enum SkipSegments {
    private struct Rule {
        let kind: SkipMarker.Kind
        let pattern: String
    }

    private static let rules: [Rule] = [
        Rule(kind: .intro, pattern: #"^(op\d*|opening( (song|theme|music|credits))?|intro|title sequence|オープニング)$"#),
        Rule(kind: .recap, pattern: #"^(recap|previously( on)?|last time( on)?|previous episode|あらすじ|前回)$"#),
        Rule(kind: .preview, pattern: #"^(preview|next( time)?( on)?|next episode( preview)?|sneak peek|次回予告|次回)$"#),
        Rule(kind: .ending, pattern: #"^(ed\d*|(final )?ending( (song|theme|music))?|closing|outro|goodbye!?|エンディング)$"#),
        Rule(kind: .credits, pattern: #"^(credits?|end credits)$"#),
    ]

    /// Every segment of the item, sorted by start. `durationSecs` may be zero when unknown; the chapters'
    /// own end then stands in for it.
    package static func make(markers: [PlexMarker], chapters: [PlexChapter], durationSecs: Double) -> [SkipMarker] {
        let server = markers.compactMap(SkipMarker.init)
        let fromChapters = chapterSegments(chapters, durationSecs: durationSecs).filter { segment in
            switch segment.kind {
            case .intro, .credits:
                return !server.contains { $0.kind == segment.kind }
            case .ending:
                return !server.contains { $0.kind == .credits && overlaps($0, segment) }
            case .recap, .preview, .commercial:
                return true
            }
        }
        return (server + fromChapters).sorted { $0.startSecs < $1.startSecs }
    }

    /// The segments the chapter names alone describe, each kept only where it sits where that kind belongs.
    package static func chapterSegments(_ chapters: [PlexChapter], durationSecs: Double) -> [SkipMarker] {
        let ordered = chapters.sorted { $0.startSecs < $1.startSecs }
        let end = durationSecs > 0 ? durationSecs : (ordered.last.map { $0.endSecs } ?? 0)
        guard end > 0 else { return [] }
        return ordered.compactMap { chapter in
            guard let kind = kind(forTitle: chapter.tag ?? "") else { return nil }
            let segment = SkipMarker(kind: kind, startSecs: chapter.startSecs, endSecs: chapter.endSecs, fromChapter: true)
            return fits(segment, durationSecs: end) ? segment : nil
        }
    }

    /// The kind a chapter title names, matched against the whole trimmed title so "Opening Credits" is never an ending.
    package static func kind(forTitle title: String) -> SkipMarker.Kind? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for rule in rules where trimmed.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return rule.kind
        }
        return nil
    }

    /// Whether a named chapter sits where its kind belongs: an intro or recap near the start, a preview,
    /// ending or credits near the end, each no longer than that kind ever runs. A mislabelled chapter fails here.
    package static func fits(_ segment: SkipMarker, durationSecs: Double) -> Bool {
        let length = segment.endSecs - segment.startSecs
        guard length > 0, segment.startSecs >= 0, segment.endSecs <= durationSecs + 1 else { return false }
        switch segment.kind {
        case .intro:
            return segment.startSecs <= 300 && (30...180).contains(length)
        case .recap:
            return segment.startSecs <= 300 && (5...180).contains(length)
        case .preview:
            return segment.startSecs >= durationSecs - 300 && (5...120).contains(length)
        case .ending:
            return segment.startSecs >= durationSecs * 0.8 && (30...180).contains(length)
        case .credits:
            return segment.startSecs >= durationSecs * 0.85 && length <= 300
        case .commercial:
            return false
        }
    }

    private static func overlaps(_ a: SkipMarker, _ b: SkipMarker) -> Bool {
        a.startSecs < b.endSecs && b.startSecs < a.endSecs
    }
}
