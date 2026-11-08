import Foundation
import MidgarCore

/// The scores the ratings strip on a detail page shows, from Trakt and the sources Trakt collects, each labelled by its
/// source. Kept for a few hours per title so moving between pages does not ask again.
@MainActor
package final class TraktScores {
    package static let shared = TraktScores()

    static let lifetime: TimeInterval = 6 * 3_600
    private var cache: [String: (scores: [TraktScore], at: Date)] = [:]

    /// The scores of `ratingKey`, or none when Trakt is not connected, the title is not matched or Trakt has none.
    package func scores(ratingKey: String, api: APIClient, now: Date = Date()) async -> [TraktScore] {
        guard TraktAccount.shared.isConnected, let server = ServerBootstrap.savedMachineIdentifier else { return [] }
        let key = "\(server)/\(ratingKey)"
        if let cached = cache[key], now.timeIntervalSince(cached.at) < Self.lifetime { return cached.scores }
        guard let target = await TraktResolver.shared.target(ratingKey: ratingKey, server: server, api: api),
              let endpoint = Self.ratingsEndpoint(for: target) else { return [] }
        do {
            let ratings = try await TraktClient.shared.send(endpoint, as: TraktRatings.self)
            cache[key] = (ratings.scores, now)
            return ratings.scores
        } catch {
            MidgarLog.notice("Trakt scores not loaded for \(ratingKey): \(error.localizedDescription)", category: .trakt)
            return []
        }
    }

    /// The scores already fetched for `ratingKey` and still fresh, so a page can lay the strip out in its first pass.
    package func cached(ratingKey: String, now: Date = Date()) -> [TraktScore] {
        guard TraktAccount.shared.isConnected, let server = ServerBootstrap.savedMachineIdentifier,
              let entry = cache["\(server)/\(ratingKey)"], now.timeIntervalSince(entry.at) < Self.lifetime else { return [] }
        return entry.scores
    }

    static func ratingsEndpoint(for target: TraktTarget) -> TraktEndpoint? {
        switch target.kind {
        case .movie:
            return .ratings(kind: .movie, ids: target.ids, season: nil, number: nil, showID: nil)
        case .show:
            guard target.season == nil else { return nil }
            return .ratings(kind: .show, ids: target.ids, season: nil, number: nil, showID: nil)
        case .episode:
            guard let showID = target.showIDs?.trakt, let season = target.season, let number = target.number else { return nil }
            return .ratings(kind: .episode, ids: target.ids, season: season, number: number, showID: showID)
        }
    }

    package func forgetAll() {
        cache = [:]
    }
}

/// Checking in: telling Trakt the viewer is watching something right now that Crucible does not play, at a cinema, on
/// live TV or at a friend's. Trakt shows it as watching and marks it watched when its runtime has passed.
package enum TraktCheckin {
    package enum Outcome: Equatable, Sendable {
        case checkedIn
        /// Already checked in to something until `until`; checking in to another title needs that one cancelled first.
        case alreadyWatching(until: Date?)
        case notMatched
    }

    /// The title the viewer is checked in to on this device and when Trakt turns it into a play, so its page offers Cancel
    /// Check-In instead of Check In until then.
    package struct Active: Codable, Equatable, Sendable {
        package let ratingKey: String
        package let until: Date
    }

    private static var activeKey: String { "trakt.checkin.\(TraktTokenStore.currentOwner)" }

    package static func active(now: Date = Date(), defaults: UserDefaults = .standard) -> Active? {
        guard let data = defaults.data(forKey: activeKey), let active = try? JSONDecoder().decode(Active.self, from: data), active.until > now else { return nil }
        return active
    }

    package static func isCheckedIn(to ratingKey: String, now: Date = Date()) -> Bool {
        active(now: now)?.ratingKey == ratingKey
    }

    private static func remember(_ active: Active?, defaults: UserDefaults = .standard) {
        guard let active, let data = try? JSONEncoder().encode(active) else { return defaults.removeObject(forKey: activeKey) }
        defaults.set(data, forKey: activeKey)
    }

    /// Checks in to `ratingKey`, which Trakt shows as watching for `durationSecs` (two hours when unknown) and then as watched.
    @MainActor
    package static func checkIn(ratingKey: String, durationSecs: Double? = nil, api: APIClient) async throws -> Outcome {
        guard let server = ServerBootstrap.savedMachineIdentifier else { throw TraktError.signedOut }
        switch await TraktResolver.shared.resolve(ratingKey: ratingKey, server: server, api: api) {
        case .unmatched:
            MidgarLog.notice("Trakt check-in to \(ratingKey) skipped: not matched", category: .trakt)
            return .notMatched
        case .unknown: throw TraktError.offline
        case .found(let target):
            guard target.kind != .show else { return .notMatched }
            do {
                try await TraktClient.shared.sendVoid(.checkin(kind: target.kind, ids: target.ids.traktOnly))
                MidgarLog.notice("Trakt check-in to \(ratingKey) accepted", category: .trakt)
                let runtime = (durationSecs ?? 0) > 0 ? durationSecs! : 7_200
                remember(Active(ratingKey: ratingKey, until: Date().addingTimeInterval(runtime)))
                return .checkedIn
            } catch TraktError.conflict(let data) {
                MidgarLog.notice("Trakt check-in to \(ratingKey) refused: already checked in", category: .trakt)
                return .alreadyWatching(until: expiry(in: data))
            }
        }
    }

    /// Cancels whatever the viewer is checked in to, so another check-in can take its place.
    package static func cancel() async throws {
        try await TraktClient.shared.sendVoid(.cancelCheckin)
        remember(nil)
        MidgarLog.notice("Trakt check-in cancelled", category: .trakt)
    }

    static func expiry(in data: Data) -> Date? {
        struct Conflict: Decodable { let expires_at: String? }
        guard let text = (try? JSONDecoder().decode(Conflict.self, from: data))?.expires_at else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
