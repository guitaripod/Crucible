import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The viewer's Seerr requests (`TVSeerrRequestsViewController`); whoever approves requests also sees everyone's and
/// decides on them here: approve, decline, retry, withdraw or remove, and open what has arrived.
@MainActor
final class SeerrRequestsScreen: SettingsScaffold {
    private enum Filter: Int, CaseIterable {
        case mine, everyone, awaiting

        var title: String {
            switch self {
            case .mine: return SeerrCopy.myRequests
            case .everyone: return SeerrCopy.everyone
            case .awaiting: return SeerrCopy.awaiting
            }
        }
    }

    private static let filterID = "seerr.requests.filter"
    private static let prefix = "seerr.requests."

    private let api: APIClient
    private let panel = ContextPanel(content: .init(symbol: "tray.full", title: SeerrCopy.requests))
    private var entries: [SeerrRequestEntry] = []
    private var filter = Filter.mine
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    private var changeObserver: (any NSObjectProtocol)?

    init(api: APIClient) {
        self.api = api
        super.init(title: SeerrCopy.requests)
        panel.wellView = BrandMarkView("seerr")
        installContext(panel)
        render()
    }

    override func screenDidAppear() {
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(forName: .seerrRequestsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    /// Loads the list for the current filter; a newer load cancels an older one, so a slow answer never replaces a newer list.
    private func reload() {
        let scope: SeerrRequests.Scope = filter == .mine ? .mine : .everyone
        let pendingOnly = filter == .awaiting
        if !loaded { presentState(.loading(title: nil)) }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let entries = try await SeerrRequests.shared.load(scope: scope, pendingOnly: pendingOnly)
                guard !Task.isCancelled, let self else { return }
                self.entries = entries
                self.loaded = true
                self.render()
                self.presentState(nil)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.entries = []
                self.loaded = true
                self.presentState(.error(title: String(localized: "Couldn’t Load"), message: error.localizedDescription,
                                         retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.reload() }))
            }
        }
    }

    private func render() {
        let connection = SeerrAccount.shared.connection?.displayName
        panel.content = .init(symbol: "tray.full", title: SeerrCopy.requests, subtitle: connection)
        var items: [RowItem] = []
        if SeerrAccount.shared.managesRequests {
            items.append(RowItem(id: Self.filterID, title: String(localized: "Show", comment: "Apple TV row that switches which Seerr requests are listed"),
                                 value: filter.title, symbol: "line.3.horizontal.decrease.circle", accessory: .chevron))
        }
        if loaded, entries.isEmpty {
            items.append(RowItem(id: "seerr.requests.empty", title: SeerrCopy.noRequestsTitle, subtitle: SeerrCopy.noRequestsText, symbol: "tray", isStatic: true))
        }
        for entry in entries {
            var lines = [[SeerrCopy.label(entry.availability), entry.seasonsLabel].compactMap { $0 }.joined(separator: " · ")]
            if let detail = SeerrCopy.detail(entry.availability) { lines.append(detail) }
            if !entry.isMine, let name = entry.request.requestedBy?.name { lines.append(SeerrCopy.requestedBy(name)) }
            let hasActions = entry.ratingKey != nil || !actions(for: entry).isEmpty
            items.append(RowItem(id: Self.prefix + String(entry.id), title: [entry.title, entry.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                 subtitle: lines.joined(separator: " · "), symbol: Symbol(SeerrCopy.symbol(entry.availability)),
                                 accessory: hasActions ? .chevron : .none, isStatic: !hasActions))
        }
        setRows(items)
    }

    /// What can be done with `entry`: a manager approves or declines what waits and retries what failed; the viewer
    /// withdraws their own request while it waits, and a manager removes any.
    private func actions(for entry: SeerrRequestEntry) -> [AlertView.Action] {
        var actions: [AlertView.Action] = []
        let manages = SeerrAccount.shared.managesRequests
        let status = entry.request.requestStatus
        if manages, status == .pending {
            actions.append(AlertView.Action(SeerrCopy.approve) { [weak self] in self?.run { try await SeerrRequests.shared.decide(entry, approve: true) } })
            actions.append(AlertView.Action(SeerrCopy.decline, role: .destructive) { [weak self] in
                self?.run { try await SeerrRequests.shared.decide(entry, approve: false) }
            })
        } else if manages, status == .failed {
            actions.append(AlertView.Action(SeerrCopy.retry) { [weak self] in self?.run { try await SeerrRequests.shared.retry(entry) } })
        }
        if (entry.isMine && status == .pending) || manages {
            let title = entry.isMine && status == .pending ? SeerrCopy.withdraw : SeerrCopy.remove
            actions.append(AlertView.Action(title, role: .destructive) { [weak self] in self?.run { try await SeerrRequests.shared.remove(entry) } })
        }
        return actions
    }

    override func rowSelected(_ id: String) {
        if id == Self.filterID {
            filter = Filter(rawValue: (filter.rawValue + 1) % Filter.allCases.count) ?? .mine
            entries = []
            loaded = false
            render()
            reload()
            return
        }
        guard id.hasPrefix(Self.prefix), let number = Int(id.dropFirst(Self.prefix.count)),
              let entry = entries.first(where: { $0.id == number }), let window else { return }
        var choices: [AlertView.Action] = []
        if let ratingKey = entry.ratingKey {
            choices.append(AlertView.Action(SeerrCopy.play) { [weak self] in self?.open(ratingKey) })
        }
        choices += actions(for: entry)
        choices.append(AlertView.Action(String(localized: "Cancel"), role: .cancel))
        AlertView(title: entry.title, message: SeerrCopy.label(entry.availability), actions: choices).present(in: window)
    }

    private func open(_ ratingKey: String) {
        let api = api
        Task { [weak self] in
            do {
                guard let item = try await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first else { return }
                self?.rootView?.push(DetailScreen.make(api: api, item: item))
            } catch {
                self?.alert(String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error))
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            do {
                try await work()
            } catch {
                MidgarLog.error("Seerr request action failed: \(error)", category: .seerr)
                self?.alert(SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func alert(_ title: String, message: String?) {
        guard let window else { return }
        AlertView.notice(title: title, message: message, in: window)
    }
}

/// Request (`TVSeerrRequestViewController`): a title the server does not have, or a show missing seasons, where it stands
/// in Seerr, the seasons to ask for and the Request button. Requesting a title the server does not have also puts it on
/// the Plex watchlist.
@MainActor
final class SeerrRequestScreen: SettingsScaffold {
    private enum RowID {
        static let submit = "seerr.request.submit"
        static let withdraw = "seerr.request.withdraw"
        static let play = "seerr.request.play"
        static let requests = "seerr.request.requests"
        static let seasonPrefix = "seerr.season."
    }

    private let api: APIClient
    private let item: PlexMetadata
    private let isOnServer: Bool
    private let panel: ContextPanel
    private var state: SeerrTitleState?
    private var failure: String?
    private var selected = Set<Int>()
    private var isWorking = false
    private var addedToWatchlist = false
    private var hasRequested = false
    private var loadTask: Task<Void, Never>?

    init(api: APIClient, item: PlexMetadata, isOnServer: Bool) {
        self.api = api
        self.item = item
        self.isOnServer = isOnServer
        panel = ContextPanel(content: .init(symbol: "plus.circle", title: item.title))
        super.init(title: SeerrCopy.request)
        installContext(panel)
        render()
        load()
    }

    /// Opens Request for `item` over `screen`, or says how to set requests up when Seerr is not connected.
    static func open(_ item: PlexMetadata, api: APIClient, isOnServer: Bool, from screen: ScreenView) {
        guard SeerrAccount.shared.isConnected else {
            guard let window = screen.window else { return }
            let message = isOnServer ? SeerrCopy.notConnectedMessage : WatchlistService.notInLibraryText + "\n\n" + SeerrCopy.notConnectedMessage
            AlertView(title: isOnServer ? SeerrCopy.notConnectedTitle : WatchlistService.notInLibraryTitle, message: message, actions: [
                AlertView.Action(SeerrCopy.setUp) { [weak screen] in screen?.rootView?.push(SeerrSettingsScreen(api: api)) },
                AlertView.Action(String(localized: "OK"), role: .cancel),
            ]).present(in: window)
            return
        }
        screen.rootView?.push(SeerrRequestScreen(api: api, item: item, isOnServer: isOnServer))
    }

    override var preferredFocusView: View? {
        guard let state, let focus = focusRowID(for: state), let row = rows.row(id: focus) else { return super.preferredFocusView }
        return row
    }

    /// The row the screen opens on: Request while it can, Withdraw while the viewer's request waits, Play once it is here.
    private func focusRowID(for state: SeerrTitleState) -> String? {
        if hasRequested { return showsPlay ? RowID.play : RowID.requests }
        if state.canRequest(with: SeerrAccount.shared.permissions) { return RowID.submit }
        if state.ownPendingRequest != nil { return RowID.withdraw }
        return showsPlay ? RowID.play : nil
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    private func load(refresh: Bool = false) {
        if state == nil { presentState(.loading(title: nil)) }
        let item = item, api = isOnServer ? api : nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let found = try await SeerrTitles.shared.state(for: item, api: api, refresh: refresh)
                guard !Task.isCancelled, let self else { return }
                guard let found else {
                    self.failure = SeerrCopy.notIdentified
                    self.render()
                    self.presentState(nil)
                    return
                }
                self.state = found
                self.failure = nil
                self.selected = Set(found.requestableSeasons)
                self.render()
                self.presentState(nil)
                if self.containsFocus, let focus = self.preferredFocusView { self.window?.focus.focus(focus, animated: false) }
            } catch {
                guard !Task.isCancelled, let self else { return }
                guard self.state == nil else {
                    self.alert(String(localized: "Couldn’t Load"), message: error.localizedDescription)
                    return
                }
                self.presentState(.error(title: String(localized: "Couldn’t Load"), message: error.localizedDescription,
                                         retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.load(refresh: true) }))
            }
        }
    }

    private var partial: Bool { SeerrAccount.shared.connection?.partialRequests ?? true }

    private var showsPlay: Bool {
        guard let state, let ratingKey = state.ratingKey, ratingKey != item.ratingKey else { return false }
        return state.availability == .available || state.availability == .partiallyAvailable
    }

    private func render() {
        var bodyParts: [String] = []
        let year = state?.year ?? item.year
        if let state {
            bodyParts.append([year.map(String.init), SeerrCopy.label(state.availability), SeerrCopy.detail(state.availability)].compactMap { $0 }
                .joined(separator: " · "))
        } else if let year {
            bodyParts.append(String(year))
        }
        if let overview = state?.overview ?? item.summary, !overview.isEmpty { bodyParts.append(overview) }
        panel.content = .init(symbol: "plus.circle", title: item.title, body: bodyParts.joined(separator: "\n\n"))
        setRows(rowItems())
    }

    private func rowItems() -> [RowItem] {
        if let failure { return [RowItem(id: "seerr.request.message", title: failure, symbol: "info.circle", isStatic: true)] }
        guard let state else { return [] }
        var items: [RowItem] = []
        let permissions = SeerrAccount.shared.permissions
        if showsPlay { items.append(RowItem(id: RowID.play, title: SeerrCopy.play, symbol: "play.fill", accessory: .chevron)) }
        if state.canRequest(with: permissions) {
            items.append(RowItem(id: RowID.submit, title: isWorking ? SeerrCopy.requesting : requestTitle, symbol: "plus.circle", isEnabled: canSubmit))
        } else if !permissions.canRequest(state.kind), state.availability == .notRequested {
            items.append(RowItem(id: "seerr.request.message", title: SeerrError.notAllowed.localizedDescription, symbol: "info.circle", isStatic: true))
        }
        if state.ownPendingRequest != nil {
            items.append(RowItem(id: RowID.withdraw, title: SeerrCopy.withdraw, symbol: "xmark.circle", isDestructive: true))
        }
        if hasRequested { items.append(RowItem(id: RowID.requests, title: SeerrCopy.seeRequests, symbol: "tray.full", accessory: .chevron)) }
        if addedToWatchlist { items.append(RowItem(id: "seerr.request.watchlisted", title: SeerrCopy.alsoWatchlist, symbol: "bookmark", isStatic: true)) }
        if state.kind == .tv, !partial, !state.requestableSeasons.isEmpty {
            items.append(RowItem(id: "seerr.request.allSeasons", title: SeerrCopy.onlyAllSeasons, symbol: "info.circle", isStatic: true))
        }
        for season in state.seasons {
            let requestable = season.status == .missing
            let chosen = requestable && (selected.contains(season.number) || !partial)
            let episodes = season.episodeCount.map { String(localized: "\($0) episodes", comment: "Number of episodes in a season") }
            let symbol = requestable ? (chosen ? "checkmark.circle.fill" : "circle") : (season.status == .available ? "play.circle" : "arrow.down.circle")
            items.append(RowItem(id: RowID.seasonPrefix + String(season.number), title: SeerrCopy.seasonName(season),
                                 subtitle: [SeerrCopy.seasonStatus(season.status), episodes].compactMap { $0 }.joined(separator: " · "),
                                 symbol: Symbol(symbol), accessory: chosen ? .checkmark : .none, isStatic: !requestable || !partial))
        }
        return items
    }

    private var requestTitle: String {
        guard let state, state.kind == .tv else { return SeerrCopy.request }
        let count = partial ? selected.count : state.requestableSeasons.count
        guard count > 0, count != state.seasons.count else { return SeerrCopy.request }
        return SeerrCopy.requestSeasons(count)
    }

    private var canSubmit: Bool {
        guard let state, !isWorking else { return false }
        if state.kind == .tv, partial { return !selected.isEmpty }
        return true
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.submit: submit()
        case RowID.withdraw: withdraw()
        case RowID.play: play()
        case RowID.requests: navigation?.push(SeerrRequestsScreen(api: api))
        default:
            guard id.hasPrefix(RowID.seasonPrefix), partial, let number = Int(id.dropFirst(RowID.seasonPrefix.count)),
                  state?.requestableSeasons.contains(number) == true else { return }
            if selected.contains(number) { selected.remove(number) } else { selected.insert(number) }
            render()
        }
    }

    private func submit() {
        guard let state, canSubmit else { return }
        isWorking = true
        render()
        let seasons = state.kind == .tv ? Array(selected).sorted() : nil
        Task { [weak self] in
            do {
                let requested = try await SeerrTitles.shared.request(state, seasons: seasons)
                guard let self else { return }
                self.state = requested
                self.selected = Set(requested.requestableSeasons)
                self.hasRequested = true
                self.isWorking = false
                self.render()
                if let focus = self.rows.row(id: self.focusRowID(for: requested) ?? ""), self.containsFocus {
                    self.window?.focus.focus(focus, animated: false)
                }
                if !self.isOnServer, let guid = self.item.guid {
                    await self.addToWatchlist(guid)
                    self.render()
                }
            } catch {
                guard let self else { return }
                MidgarLog.error("Seerr request failed: \(error)", category: .seerr)
                self.isWorking = false
                self.render()
                self.alert(SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func addToWatchlist(_ guid: String) async {
        let token = api.token
        if let listed = try? await WatchlistService.items(token: token), WatchlistService.contains(guid: guid, in: listed) {
            addedToWatchlist = true
            return
        }
        do {
            try await WatchlistService.add(guid: guid, token: token)
            addedToWatchlist = true
        } catch {
            MidgarLog.notice("Requested title not added to the watchlist: \(error.localizedDescription)", category: .seerr)
        }
    }

    private func withdraw() {
        guard let state, let request = state.ownPendingRequest else { return }
        isWorking = true
        render()
        Task { [weak self] in
            do {
                let withdrawn = try await SeerrTitles.shared.withdraw(request, of: state)
                self?.state = withdrawn
                self?.selected = Set(withdrawn.requestableSeasons)
            } catch {
                self?.alert(SeerrCopy.connectFailed, message: error.localizedDescription)
            }
            self?.isWorking = false
            self?.render()
        }
    }

    private func play() {
        guard let ratingKey = state?.ratingKey else { return }
        let api = api
        Task { [weak self] in
            do {
                guard let local = try await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first else { return }
                self?.rootView?.push(DetailScreen.make(api: api, item: local))
            } catch {
                self?.alert(String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error))
            }
        }
    }

    private func alert(_ title: String, message: String?) {
        guard let window else { return }
        AlertView.notice(title: title, message: message, in: window)
    }
}
