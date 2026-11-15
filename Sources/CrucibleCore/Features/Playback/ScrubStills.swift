import Foundation

/// The preview stills a Plex server keeps for a file once video preview thumbnails are on: one every few seconds, served
/// one at a time as the still nearest an offset (`/library/parts/{id}/indexes/sd/{ms}`, a 404 when there are none).
package enum ScrubStills {
    /// The part whose stills a scrubber shows, when the server has made them for it.
    package static func part(of media: PlexMedia?) -> PlexPart? {
        guard let part = media?.Part?.first, part.indexes == "sd" else { return nil }
        return part
    }

    /// The whole second a still is asked for at, so a scrubber moving within one second asks once.
    package static func second(_ seconds: Double) -> Int {
        seconds.isFinite ? Int(max(seconds, 0).rounded()) : 0
    }

    package static func path(partID: Int, second: Int) -> String {
        "/library/parts/\(partID)/indexes/sd/\(second * 1000)"
    }

    /// How far the nearest held still may be from where the scrubber points and still stand in for it while the right
    /// one loads.
    package static let standInReach = 30
}

/// Which still to ask the server for next: one request at a time, always for where the scrubber points now, so a held
/// scrub asks for no stale positions. A file whose first request fails before any still arrived has none, and is asked
/// nothing more.
package struct ScrubStillQueue: Equatable, Sendable {
    package private(set) var inFlight: Int?
    package private(set) var isUnavailable = false
    private var wanted: Int?
    private var hasLanded = false

    package init() {}

    /// The scrubber points at `second`; `held` when that still is already in hand. Returns the second to ask for now.
    package mutating func want(_ second: Int, held: Bool) -> Int? {
        guard !isUnavailable else { return nil }
        wanted = held ? nil : second
        guard !held, inFlight == nil else { return nil }
        inFlight = second
        return second
    }

    /// The request in flight came back, with a still or without. Returns the second to ask for next.
    package mutating func landed(_ succeeded: Bool) -> Int? {
        let finished = inFlight
        inFlight = nil
        if succeeded {
            hasLanded = true
        } else if !hasLanded {
            isUnavailable = true
            wanted = nil
            return nil
        }
        guard let next = wanted, next != finished else {
            wanted = nil
            return nil
        }
        inFlight = next
        return next
    }

    /// The nearest of `held` to `second` within `ScrubStills.standInReach`, shown until the right still arrives.
    package static func standIn(for second: Int, among held: some Sequence<Int>) -> Int? {
        held.filter { abs($0 - second) <= ScrubStills.standInReach }.min { abs($0 - second) < abs($1 - second) }
    }
}
