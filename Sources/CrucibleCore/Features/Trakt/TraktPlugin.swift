import Foundation
import MidgarCore

/// A play Trakt recorded, for the player's banner.
package struct TraktWatchedNotice: Sendable {
    package let ratingKey: String
    package let title: String
    package let subtitle: String?
}

extension Notification.Name {
    /// Posted on the main thread with a `TraktWatchedNotice` as the object when Trakt recorded a finished play.
    package static let traktMarkedWatched = Notification.Name("crucible.traktMarkedWatched")
}

/// Trakt as an integration: it follows playback (scrobbling), sends the changes the viewer makes (watched, unwatched,
/// ratings) and keeps a queue of what could not be sent yet. It does nothing until the viewer connects an account.
@MainActor
package final class TraktPlugin: IntegrationPlugin {
    package static let shared = TraktPlugin()

    package let id = "trakt"
    private let account: TraktAccount
    private let resolver: TraktResolver
    private let outbox: TraktOutbox
    private let client: TraktClient

    package init(
        account: TraktAccount = .shared,
        resolver: TraktResolver = .shared,
        outbox: TraktOutbox = .shared,
        client: TraktClient = .shared
    ) {
        self.account = account
        self.resolver = resolver
        self.outbox = outbox
        self.client = client
    }

    package var isActive: Bool { account.isConnected }

    package func makePlaybackWatcher(for subject: PlaybackSubject) -> PlaybackWatching? {
        guard account.choices.scrobbles, !account.choices.anotherAppScrobbles else { return nil }
        guard subject.mediaType == "movie" || subject.mediaType == "episode" else { return nil }
        return TraktScrobbleWatcher(subject: subject, plugin: self)
    }

    package func watchedChanged(_ ratingKey: String, watched: Bool, api: APIClient, server: String) {
        guard account.choices.sendsChanges else { return }
        if !watched, !account.choices.removesPlaysOnUnwatch { return }
        let change = TraktPendingChange(ratingKey: ratingKey, server: server, owner: TraktTokenStore.currentOwner, action: watched ? .watched(at: Date()) : .unwatched)
        Task { await send(change, api: api) }
    }

    package func ratingChanged(_ ratingKey: String, rating: UserRating?, api: APIClient, server: String) {
        guard account.choices.sendsChanges else { return }
        let change = TraktPendingChange(ratingKey: ratingKey, server: server, owner: TraktTokenStore.currentOwner, action: rating.map { .rated($0.halfStars) } ?? .unrated)
        Task { await send(change, api: api) }
    }

    /// Loads the account and starts sending what waits without holding up the other plugins: the outbox sends one change
    /// a second, which for a long queue takes minutes.
    package func launched(api: APIClient, server: String) async {
        await account.load()
        Task { await self.flush(server: server, api: api) }
    }

    package func signedOut() async {
        await account.forgetEveryProfile()
    }

    /// Sends what is still waiting for `server`, then nothing else; called after launch, when the app returns and after a play.
    package func flush(server: String, api: APIClient) async {
        guard isActive, !outbox.pending.isEmpty else { return }
        await outbox.drain(server: server, owner: TraktTokenStore.currentOwner) { change in try await self.deliver(change, api: api) }
    }

    /// Sends `change` now, or queues it when Trakt or the server cannot be reached.
    func send(_ change: TraktPendingChange, api: APIClient) async {
        do {
            try await deliver(change, api: api)
        } catch let error as TraktError where error.isTransient {
            outbox.add(change)
        } catch TraktError.unauthorized, TraktError.signedOut {
            account.tokenRefused()
            outbox.add(change)
        } catch {
            MidgarLog.notice("Trakt did not take a change for \(change.ratingKey): \(error.localizedDescription)", category: .trakt)
        }
    }

    /// Delivers one change; throws a transient error when it should wait in the queue.
    func deliver(_ change: TraktPendingChange, api: APIClient) async throws {
        let target: TraktTarget
        switch await resolver.resolve(ratingKey: change.ratingKey, server: change.server, api: api) {
        case .found(let found): target = found
        case .unmatched: return
        case .unknown: throw TraktError.offline
        }
        switch change.action {
        case .watched(let at):
            try await postPlay(of: target, at: at)
        case .unwatched:
            try await client.sendVoid(.removeHistory(Self.items(for: target, watchedAt: nil, rating: nil)))
        case .rated(let value):
            try await client.sendVoid(.addRatings(Self.items(for: target, watchedAt: nil, rating: value, ratedAt: change.madeAt)))
        case .unrated:
            try await client.sendVoid(.removeRatings(Self.items(for: target, watchedAt: nil, rating: nil)))
        }
    }

    /// Adds one play to the history, unless the ledger says this very play was already sent.
    func postPlay(of target: TraktTarget, at date: Date) async throws {
        if let traktID = target.ids.trakt, target.kind != .show, outbox.wasSent(traktID: traktID, at: date) { return }
        try await client.sendVoid(.addHistory(Self.items(for: target, watchedAt: date, rating: nil)))
        if let traktID = target.ids.trakt, target.kind != .show { outbox.noteSent(traktID: traktID, at: date) }
    }

    /// The body of a history or rating write for `target`. A season is its show with that season; a show is all of it.
    nonisolated static func items(for target: TraktTarget, watchedAt: Date?, rating: Int?, ratedAt: Date? = nil) -> TraktSyncItems {
        let watched = watchedAt.map(TraktDate.string)
        let rated = rating == nil ? nil : TraktDate.string(ratedAt ?? Date())
        switch target.kind {
        case .movie:
            return TraktSyncItems(movies: [.init(ids: target.ids.traktOnly, watchedAt: watched, rating: rating, ratedAt: rated)])
        case .episode:
            return TraktSyncItems(episodes: [.init(ids: target.ids.traktOnly, watchedAt: watched, rating: rating, ratedAt: rated)])
        case .show:
            let seasons = target.season.map { [TraktSyncItems.Season(number: $0, watchedAt: watched, rating: rating, ratedAt: rated)] }
            let showRating = seasons == nil ? rating : nil
            return TraktSyncItems(shows: [.init(ids: target.ids.traktOnly, watchedAt: seasons == nil ? watched : nil, rating: showRating, ratedAt: showRating == nil ? nil : rated, seasons: seasons)])
        }
    }

    /// Records a finished play the scrobble could not mark watched (an early credits marker, an offline download, Trakt down).
    func recordFinishedPlay(_ subject: PlaybackSubject, at date: Date) async {
        let change = TraktPendingChange(ratingKey: subject.ratingKey, server: subject.server, owner: TraktTokenStore.currentOwner, action: .watched(at: date), madeAt: date)
        await send(change, api: subject.api)
    }

    func announceWatched(_ subject: PlaybackSubject) {
        let subtitle: String?
        if subject.isEpisode, let show = subject.showTitle {
            subtitle = [show, subject.seasonNumber.map { "S\($0)" }, subject.episodeNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " · ")
        } else {
            subtitle = nil
        }
        NotificationCenter.default.post(name: .traktMarkedWatched, object: TraktWatchedNotice(ratingKey: subject.ratingKey, title: subject.title, subtitle: subtitle))
    }

    var resolverForWatchers: TraktResolver { resolver }
    var accountForWatchers: TraktAccount { account }
    var clientForWatchers: TraktClient { client }
}

/// Scrobbles one playback: `start` when it plays, `pause` when it pauses or stops early, `stop` when it ends. Calls leave
/// one at a time in the order they were made, so a stop never lands before the start it ends.
@MainActor
final class TraktScrobbleWatcher: PlaybackWatching {
    private let subject: PlaybackSubject
    private let plugin: TraktPlugin
    private var lastAction: TraktScrobbleAction?
    private var pending: Task<Void, Never>?
    private var target: TraktResolution?

    /// Trakt marks a stop at this progress or more as watched; below it, a stop only saves the place.
    static let watchedProgress: Double = 80

    init(subject: PlaybackSubject, plugin: TraktPlugin) {
        self.subject = subject
        self.plugin = plugin
    }

    func playback(_ change: PlaybackChange) {
        switch change {
        case .playing(let position):
            guard lastAction != .start else { return }
            lastAction = .start
            enqueue { watcher in await watcher.scrobble(.start, at: position) }
        case .paused(let position):
            guard lastAction == .start else { return }
            lastAction = .pause
            enqueue { watcher in await watcher.scrobble(.pause, at: position) }
        case .stopped(let position, let finished, let date):
            guard lastAction != .stop else { return }
            let started = lastAction != nil
            lastAction = .stop
            enqueue { watcher in await watcher.finish(at: position, finished: finished, date: date, started: started) }
        }
    }

    private func enqueue(_ work: @escaping @MainActor (TraktScrobbleWatcher) async -> Void) {
        let previous = pending
        pending = Task { [self] in
            await previous?.value
            await work(self)
        }
    }

    private func resolvedTarget() async -> TraktResolution {
        if let target, target != .unknown { return target }
        let resolved = await plugin.resolverForWatchers.resolve(ratingKey: subject.ratingKey, server: subject.server, api: subject.api)
        target = resolved
        return resolved
    }

    @discardableResult
    private func scrobble(_ action: TraktScrobbleAction, at position: Double) async -> String? {
        guard case .found(let target) = await resolvedTarget() else { return nil }
        let progress = subject.progress(at: position)
        guard progress >= 1 || action != .stop else { return nil }
        do {
            let result = try await plugin.clientForWatchers.send(
                .scrobble(action, kind: target.kind, ids: target.ids.traktOnly, progress: max(progress, 0.01)),
                as: TraktScrobbleResult.self
            )
            return result.action
        } catch TraktError.conflict {
            return "scrobble"
        } catch TraktError.unauthorized, TraktError.signedOut {
            plugin.accountForWatchers.tokenRefused()
            return nil
        } catch {
            MidgarLog.notice("Trakt scrobble \(action.rawValue) not sent for \(subject.ratingKey): \(error.localizedDescription)", category: .trakt)
            return nil
        }
    }

    private func finish(at position: Double, finished: Bool, date: Date, started: Bool) async {
        let progress = subject.progress(at: position)
        guard finished else {
            if started { await scrobble(.pause, at: position) }
            return
        }
        guard case .found = await resolvedTarget() else { return }
        var recorded = false
        if progress >= Self.watchedProgress {
            let action = await scrobble(.stop, at: position)
            recorded = action != nil
        } else if started {
            await scrobble(.pause, at: position)
        }
        if !recorded {
            await plugin.recordFinishedPlay(subject, at: date)
        }
        plugin.announceWatched(subject)
        await plugin.flush(server: subject.server, api: subject.api)
    }
}
