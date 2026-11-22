import Foundation

/// Moves a server's intro marker onto the picture's own edges. Plex finds an intro by its theme music, which often begins over
/// the last shot of the cold open and stops a little before the title card fades out, so its marker starts seconds early
/// (an automatic skip cuts off the cold open's last line) and ends early (a skip lands on the intro's tail). Measured on
/// The Office: starts 0.7 to 3.2 seconds before the cut into the titles, ends 0.4 to 2.6 seconds before the black after
/// them. The start moves to the first cut or black after it, unless it already sits on one; the end moves to where the
/// black after the titles ends, else to a cut just after it. Nothing moves further than these windows, so a marker on a
/// title with no clear edge stays as the server made it.
package enum MarkerSnap {
    /// A picture's edges near a marker, on the item's timeline in seconds.
    package struct Edges: Equatable, Sendable {
        package var cuts: [Double]
        package var blackEnds: [Double]

        package init(cuts: [Double] = [], blackEnds: [Double] = []) {
            self.cuts = cuts
            self.blackEnds = blackEnds
        }
    }

    /// How far around a marker's start and end the picture is read, in seconds.
    package static let startWindow = (before: 1.0, after: 4.5)
    package static let endWindow = (before: 1.5, after: 4.0)

    package static func refined(_ marker: SkipMarker, start: Edges, end: Edges) -> SkipMarker {
        guard marker.kind == .intro, !marker.fromChapter else { return marker }
        let newStart = refinedStart(marker.startSecs, edges: start)
        let newEnd = refinedEnd(marker.endSecs, edges: end)
        guard newEnd > newStart + 1 else { return marker }
        return SkipMarker(kind: marker.kind, startSecs: newStart, endSecs: newEnd, fromChapter: marker.fromChapter)
    }

    static func refinedStart(_ start: Double, edges: Edges) -> Double {
        guard start > 0.5 else { return start }
        let all = (edges.cuts + edges.blackEnds).sorted()
        if all.contains(where: { abs($0 - start) <= 0.5 }) { return start }
        return all.first { $0 > start && $0 <= start + 4 } ?? start
    }

    static func refinedEnd(_ end: Double, edges: Edges) -> Double {
        if let black = edges.blackEnds.filter({ $0 >= end - 1 && $0 <= end + 3.5 }).min(by: { abs($0 - end) < abs($1 - end) }) { return black }
        return edges.cuts.filter { $0 >= end - 0.5 && $0 <= end + 1.5 }.min { abs($0 - end) < abs($1 - end) } ?? end
    }

    /// Reads the cuts and blacks from what ffmpeg's `scdet` and `blackdetect` print for a window read from `offset`.
    package static func edges(fromFFmpeg output: String, offset: Double) -> Edges {
        var edges = Edges()
        for line in output.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "lavfi.scd.time: "), let value = Double(line[range.upperBound...].prefix { !$0.isWhitespace }) {
                edges.cuts.append(offset + value)
            }
            if let range = line.range(of: "black_end:"), let value = Double(line[range.upperBound...].prefix { !$0.isWhitespace }) {
                edges.blackEnds.append(offset + value)
            }
        }
        return edges
    }
}
