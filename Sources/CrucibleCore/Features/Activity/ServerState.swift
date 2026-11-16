import Foundation
import MidgarCore

/// What changed on the server for the screens that show its titles: watched state, progress, Continue Watching and On Deck,
/// titles that arrived or left.
package struct ServerStateChange: Sendable, Equatable {
    /// Anything may have changed: the app was away, or the live event stream was down and events may have been missed.
    package var everything: Bool
    /// Titles whose watched state or progress moved, or that arrived in or left a library.
    package var ratingKeys: Set<String>
    /// Libraries that gained, lost or rescanned titles.
    package var sectionIDs: Set<String>
    /// Whether a watched state or a position moved, which any library's grid may show through a show's unwatched count.
    package var movesWatchState: Bool

    package init(everything: Bool = false, ratingKeys: Set<String> = [], sectionIDs: Set<String> = [], movesWatchState: Bool = false) {
        self.everything = everything
        self.ratingKeys = ratingKeys
        self.sectionIDs = sectionIDs
        self.movesWatchState = movesWatchState
    }

    package static let everything = ServerStateChange(everything: true)

    /// The watched state or progress of `ratingKeys` moved; empty keys are left out.
    package static func titles(_ ratingKeys: [String?]) -> ServerStateChange {
        ServerStateChange(ratingKeys: Set(ratingKeys.compactMap { $0 }.filter { !$0.isEmpty }), movesWatchState: true)
    }

    package var isEmpty: Bool { !everything && ratingKeys.isEmpty && sectionIDs.isEmpty && !movesWatchState }

    /// Whether a library grid of `sectionID` shows anything this change moved: a watched state anywhere, or its own titles.
    package func touchesLibrary(_ sectionID: String) -> Bool {
        everything || movesWatchState || sectionIDs.contains(sectionID)
    }

    /// Whether a screen showing `ratingKeys`, from the library `sectionID` when it lists titles that may arrive, has anything to
    /// ask again.
    package func touches(_ ratingKeys: some Sequence<String>, sectionID: String? = nil) -> Bool {
        if everything { return true }
        if let sectionID, sectionIDs.contains(sectionID) { return true }
        return ratingKeys.contains { self.ratingKeys.contains($0) }
    }

    package mutating func merge(_ other: ServerStateChange) {
        everything = everything || other.everything
        ratingKeys.formUnion(other.ratingKeys)
        sectionIDs.formUnion(other.sectionIDs)
        movesWatchState = movesWatchState || other.movesWatchState
    }
}

/// The one place that hears about everything that changes the server's titles, from wherever it comes: this device marking a
/// title watched or finishing a playback, another device pausing or stopping, a library scan, or the app coming back after
/// being away. Each change drops the titles every client keeps, so the next read asks the server, and reaches every screen
/// that follows it, at once when it is on screen and on its next appearance otherwise.
///
/// While the main app is up it keeps the server's event stream open, closes it while the app is away and, when the app
/// returns, first hands the server what this device still owes it (positions saved while suspended, queued integration
/// changes) and then asks every screen to read again, so nothing on screen predates the return.
@MainActor
package final class ServerStateSync {
    package static let shared = ServerStateSync()

    /// How long events from the server are gathered before screens hear of them: a scan or a remote session sends many at once.
    package static let eventGathering: Duration = .seconds(1)
    /// The longest the return to the foreground waits on this device's owed reports before the screens read again.
    package static let foregroundReportBudget: Duration = .seconds(3)

    private var observers: [UUID: @MainActor (ServerStateChange) -> Void] = [:]
    private var pending = ServerStateChange()
    private var delivery: Task<Void, Never>?
    private var deliversImmediately = false
    private var api: APIClient?
    private var server: String?
    private var listening: ServerEventListening?
    private var resyncToken: UUID?
    private var returnTask: Task<Void, Never>?
    private let hub: ServerEventHub

    package init(hub: ServerEventHub = .shared) {
        self.hub = hub
    }

    package func addObserver(_ handler: @escaping @MainActor (ServerStateChange) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    package func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    /// Announces `change`. Every client of the attached session forgets what it keeps at once; the screens hear of it on the
    /// next turn, together with anything else announced meanwhile, or after `gathering` for changes that come in bursts.
    package func post(_ change: ServerStateChange, gathering: Duration = .zero) {
        guard !change.isEmpty else { return }
        if let api { APIClient.invalidateCaches(token: api.token) }
        pending.merge(change)
        let immediate = gathering == .zero
        if delivery != nil, immediate, !deliversImmediately {
            delivery?.cancel()
            delivery = nil
        }
        guard delivery == nil else { return }
        deliversImmediately = immediate
        delivery = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: gathering) }
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func deliver() {
        delivery = nil
        let change = pending
        pending = ServerStateChange()
        guard !change.isEmpty else { return }
        observers.values.forEach { $0(change) }
    }

    /// The main app is up on `server` through `api`: follow the server's events until `detach`.
    package func attach(api: APIClient, server: String) {
        guard self.api !== api || self.server != server else { return }
        detach()
        self.api = api
        self.server = server
        listening = hub.follow(api: api) { [weak self] event in
            guard let change = event.stateChange else { return }
            self?.post(change, gathering: Self.eventGathering)
        }
        resyncToken = hub.onResync { [weak self] in
            self?.post(.everything)
        }
    }

    /// Signed out, or about to connect to another server.
    package func detach() {
        listening?.cancel()
        listening = nil
        if let resyncToken { hub.removeResyncHandler(resyncToken) }
        resyncToken = nil
        returnTask?.cancel()
        returnTask = nil
        api = nil
        server = nil
    }

    /// The app left the foreground: the event stream would be cut by the system anyway. A return still reporting what the
    /// device owes carries on, so a quick trip away does not leave it unsent.
    package func enteredBackground() {
        hub.suspend()
    }

    /// The app is back: whatever happened meanwhile on other devices was never heard, so the event stream opens again, the
    /// server first gets what this device still owes it, and then every screen reads again.
    package func enteredForeground() {
        hub.resume()
        guard let api, let server else { return }
        APIClient.invalidateCaches(token: api.token)
        returnTask?.cancel()
        returnTask = Task { [weak self] in
            await PlaybackResumeSync.flush(api: api, server: server, within: Self.foregroundReportBudget)
            guard !Task.isCancelled, let self else { return }
            returnTask = nil
            MidgarLog.notice("Back in the foreground: reading the server's state again", category: .lifecycle)
            post(.everything)
            await Integrations.returned(api: api, server: server)
        }
    }
}

/// A screen's hold on server state changes. While the screen is on screen a change it cares about refreshes it, at most once
/// every `interval` so a library scan does not keep it reading; otherwise the change is remembered and answered when the screen
/// appears again. Ends when the follower goes away.
@MainActor
package final class ServerStateFollower {
    package static let defaultInterval: Duration = .seconds(3)

    private var token: UUID?
    private let center: ServerStateSync
    private let interval: Duration
    private let isOnScreen: @MainActor () -> Bool
    private let refresh: @MainActor () -> Void
    private var lastRefresh: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?
    private(set) var isStale = false

    package init(
        center: ServerStateSync = .shared,
        every interval: Duration = defaultInterval,
        matching matches: @escaping @MainActor (ServerStateChange) -> Bool = { _ in true },
        isOnScreen: @escaping @MainActor () -> Bool,
        refresh: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.interval = interval
        self.isOnScreen = isOnScreen
        self.refresh = refresh
        token = center.addObserver { [weak self] change in
            guard let self, matches(change) else { return }
            refreshSoon()
        }
    }

    /// Whether a change arrived while the screen was away, forgetting it: a screen that does not read again on every
    /// appearance answers true with a refresh.
    package func takeStale() -> Bool {
        defer { isStale = false }
        return isStale
    }

    /// The screen could not take a change right now, in the middle of something the viewer is doing: it is answered by the
    /// next `takeStale`.
    package func markStale() {
        isStale = true
    }

    package func cancel() {
        if let token { center.removeObserver(token) }
        token = nil
        trailing?.cancel()
        trailing = nil
    }

    private func refreshSoon() {
        guard trailing == nil else { return }
        if let lastRefresh, lastRefresh.duration(to: .now) < interval {
            let due = lastRefresh.advanced(by: interval)
            trailing = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                trailing = nil
                fire()
            }
            return
        }
        fire()
    }

    private func fire() {
        guard isOnScreen() else {
            isStale = true
            return
        }
        isStale = false
        lastRefresh = .now
        refresh()
    }

    deinit {
        trailing?.cancel()
        if let token {
            Task { @MainActor [center] in center.removeObserver(token) }
        }
    }
}
