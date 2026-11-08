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

    @MainActor
    package static func checkIn(ratingKey: String, api: APIClient) async throws -> Outcome {
        guard let server = ServerBootstrap.savedMachineIdentifier else { throw TraktError.signedOut }
        switch await TraktResolver.shared.resolve(ratingKey: ratingKey, server: server, api: api) {
        case .unmatched: return .notMatched
        case .unknown: throw TraktError.offline
        case .found(let target):
            guard target.kind != .show else { return .notMatched }
            do {
                try await TraktClient.shared.sendVoid(.checkin(kind: target.kind, ids: target.ids.traktOnly))
                return .checkedIn
            } catch TraktError.conflict(let data) {
                return .alreadyWatching(until: expiry(in: data))
            }
        }
    }

    /// Cancels whatever the viewer is checked in to, so another check-in can take its place.
    package static func cancel() async throws {
        try await TraktClient.shared.sendVoid(.cancelCheckin)
    }

    static func expiry(in data: Data) -> Date? {
        struct Conflict: Decodable { let expires_at: String? }
        guard let text = (try? JSONDecoder().decode(Conflict.self, from: data))?.expires_at else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
