import Foundation
import MidgarCore

/// The Rate What You Watched row: the ledger's asks, minus any title the server already has a rating for. The server is
/// asked about a title at most every twelve hours, a few titles at a time, so a rating given in another Plex app clears the
/// row without a request for every card on every visit.
@MainActor
package final class RatingAsksFeed {
    private struct Answer: Sendable {
        let rating: Double?
        let poster: String?
    }

    private let ledger: FinishedTitlesLedger
    private let server: () -> String?
    private let fetchRating: @Sendable (String) async throws -> (rating: Double?, poster: String?)

    package init(
        ledger: FinishedTitlesLedger,
        server: @escaping () -> String?,
        fetchRating: @escaping @Sendable (String) async throws -> (rating: Double?, poster: String?)
    ) {
        self.ledger = ledger
        self.server = server
        self.fetchRating = fetchRating
    }

    package convenience init(api: APIClient) {
        self.init(
            ledger: .shared,
            server: { ServerBootstrap.savedMachineIdentifier },
            fetchRating: { ratingKey in
                let item = try await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first
                return (item?.userRating, item?.thumb)
            }
        )
    }

    /// The asks as the ledger has them now, without asking the server anything.
    package func current(now: Date = Date()) -> [RatingAsk] {
        ledger.asks(now: now, server: server())
    }

    /// Checks the asks the server has not been asked about lately, then returns what is left to ask.
    package func load(now: Date = Date()) async -> [RatingAsk] {
        let due = current(now: now).filter { ledger.needsCheck($0.ratingKey, now: now) }
        guard !due.isEmpty else { return current(now: now) }
        let fetch = fetchRating
        let answers = await withTaskGroup(of: (String, Answer?).self) { group in
            for ask in due {
                group.addTask {
                    do {
                        let found = try await fetch(ask.ratingKey)
                        return (ask.ratingKey, Answer(rating: found.rating, poster: found.poster))
                    } catch {
                        return (ask.ratingKey, nil)
                    }
                }
            }
            var collected = [(String, Answer?)]()
            for await answer in group { collected.append(answer) }
            return collected
        }
        for (ratingKey, answer) in answers {
            guard let answer else { continue }
            if UserRating(plexValue: answer.rating) != nil {
                ledger.noteRated(ratingKey, isRated: true, at: now)
            } else {
                ledger.noteChecked(ratingKey, at: now, poster: answer.poster)
            }
        }
        return current(now: now)
    }
}
