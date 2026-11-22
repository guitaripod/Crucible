import Foundation
import MidgarCore

/// The intro a paired Crucible Server moved onto the picture's own edges (`MarkerSnap`, measured there with ffmpeg), for a
/// device that cannot read the file itself. Without a paired server, or when it does not answer, the server's marker stays.
package enum IntroSharpening {
    /// `segments` with the intro the paired server sharpened, or nil when nothing changed.
    package static func fromServer(_ segments: [SkipMarker], ratingKey: String) async -> [SkipMarker]? {
        guard let intro = segments.first(where: { $0.kind == .intro && !$0.fromChapter }),
              let server = CompanionStore.current(), let token = ServerBootstrap.connection()?.authToken else { return nil }
        guard let found = try? await CompanionClient(server: server, plexToken: token).segments(ratingKey: ratingKey) else { return nil }
        return replacing(intro, in: segments, with: found)
    }

    /// The server's intro in place of `intro`, when it is the same intro moved no further than `MarkerSnap` moves one.
    static func replacing(_ intro: SkipMarker, in segments: [SkipMarker], with found: [CompanionSegment]) -> [SkipMarker]? {
        guard let match = found.first(where: { $0.kind == "intro" && $0.source == "plex" }) else { return nil }
        let start = Double(match.startMs) / 1000, end = Double(match.endMs) / 1000
        guard start >= intro.startSecs - 0.01, start <= intro.startSecs + 4.01, end >= intro.endSecs - 1.01, end <= intro.endSecs + 3.51,
              end > start + 1, start != intro.startSecs || end != intro.endSecs else { return nil }
        let refined = SkipMarker(kind: .intro, startSecs: start, endSecs: end)
        MidgarLog.notice("Intro sharpened by Crucible Server: \(intro.startSecs)–\(intro.endSecs) to \(start)–\(end)", category: .playback)
        return segments.map { $0 == intro ? refined : $0 }
    }
}
