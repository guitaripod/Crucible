import Foundation
import MidgarCore

/// A change Crucible owes Trakt and could not send yet: a play finished offline or while Trakt was down, a rating, or a
/// title marked watched or unwatched.
package struct TraktPendingChange: Codable, Equatable, Sendable {
    package enum Action: Codable, Equatable, Sendable {
        case watched(at: Date)
        case unwatched
        case rated(Int)
        case unrated
    }

    package let ratingKey: String
    package let server: String
    /// The Plex account or Home profile whose Trakt account it goes to.
    package let owner: String
    package let action: Action
    package let madeAt: Date

    package init(ratingKey: String, server: String, owner: String, action: Action, madeAt: Date = Date()) {
        self.ratingKey = ratingKey
        self.server = server
        self.owner = owner
        self.action = action
        self.madeAt = madeAt
    }
}

/// Changes waiting for Trakt, sent in the order they were made once Trakt can be reached, and a ledger of the plays
/// already sent so a retry never adds the same play twice (Trakt's history does not deduplicate).
@MainActor
package final class TraktOutbox {
    package static let shared = TraktOutbox()

    /// The longest a change waits before it is given up: a month of being offline or unmatched.
    static let lifetime: TimeInterval = 30 * 86_400
    static let capacity = 500
    static let ledgerCapacity = 2_000

    private let storage: URL?
    private var state: State
    private var draining = false

    private struct State: Codable {
        var pending: [TraktPendingChange] = []
        var sentPlays: [String] = []
    }

    package init(storage: URL? = TraktOutbox.defaultStorage) {
        self.storage = storage
        state = storage.flatMap { try? JSONDecoder().decode(State.self, from: Data(contentsOf: $0)) } ?? State()
    }

    package static var defaultStorage: URL {
        AppPlatform.persistentDirectory.appendingPathComponent("trakt-outbox.json")
    }

    package var pending: [TraktPendingChange] { state.pending }

    package func add(_ change: TraktPendingChange) {
        state.pending.removeAll { $0.ratingKey == change.ratingKey && $0.server == change.server && $0.owner == change.owner && Self.supersedes(change.action, $0.action) }
        state.pending.append(change)
        if state.pending.count > Self.capacity { state.pending.removeFirst(state.pending.count - Self.capacity) }
        save()
    }

    /// A rating replaces an earlier rating of the same title, and watched and unwatched replace each other; plays add up.
    private static func supersedes(_ new: TraktPendingChange.Action, _ old: TraktPendingChange.Action) -> Bool {
        switch (new, old) {
        case (.rated, .rated), (.rated, .unrated), (.unrated, .rated), (.unrated, .unrated): return true
        case (.unwatched, .watched), (.unwatched, .unwatched): return true
        default: return false
        }
    }

    /// Whether a play of `traktID` at `date` (to the minute, as Trakt keeps it) was already sent.
    package func wasSent(traktID: Int, at date: Date) -> Bool {
        state.sentPlays.contains(Self.playKey(traktID: traktID, at: date))
    }

    package func noteSent(traktID: Int, at date: Date) {
        let key = Self.playKey(traktID: traktID, at: date)
        guard !state.sentPlays.contains(key) else { return }
        state.sentPlays.append(key)
        if state.sentPlays.count > Self.ledgerCapacity { state.sentPlays.removeFirst(state.sentPlays.count - Self.ledgerCapacity) }
        save()
    }

    private static func playKey(traktID: Int, at date: Date) -> String {
        "\(traktID)@\(Int(date.timeIntervalSince1970 / 60))"
    }

    /// Forgets what `owner` was owed, and the ledger with it when nobody else is left.
    package func clear(owner: String) {
        state.pending.removeAll { $0.owner == owner }
        if state.pending.isEmpty { state.sentPlays = [] }
        save()
    }

    package func clear() {
        state = State()
        if let storage { try? FileManager.default.removeItem(at: storage) }
    }

    /// Sends what is waiting for `server` through `send`, oldest first. A change Trakt refuses for good is dropped; one that
    /// failed for a passing reason stays, and the drain stops there to keep the order.
    package func drain(server: String, owner: String, now: Date = Date(), send: (TraktPendingChange) async throws -> Void) async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        state.pending.removeAll { now.timeIntervalSince($0.madeAt) > Self.lifetime }
        for change in state.pending where change.server == server && change.owner == owner {
            do {
                try await send(change)
                remove(change)
            } catch let error as TraktError where error.isTransient {
                break
            } catch is CancellationError {
                break
            } catch {
                MidgarLog.notice("Trakt dropped a queued change for \(change.ratingKey): \(error.localizedDescription)", category: .trakt)
                remove(change)
            }
        }
        save()
    }

    private func remove(_ change: TraktPendingChange) {
        if let index = state.pending.firstIndex(of: change) { state.pending.remove(at: index) }
    }

    private func save() {
        guard let storage, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: storage, options: .atomic)
    }
}
