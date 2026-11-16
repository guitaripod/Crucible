import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Server Activity and the owner's Server Dashboard (`TVScreens.serverActivity`, `TVServerDashboardViewController`).
@MainActor
enum OwnerScreens {
    /// Who is watching what on the server now: a card per stream with its progress, refreshed every ten seconds and when
    /// playback starts or stops anywhere; the owner can stop a stream with a reason.
    static func activity(api: APIClient) -> TitleGridScreen {
        let grid = TitleGridScreen(api: api, title: ServerActivity.title, empty: .init(
            symbol: "dot.radiowaves.left.and.right", title: ServerActivity.emptyTitle, message: ServerActivity.emptyText
        )) { try await ServerActivity.sessions(api: api) }
        grid.card = { session in
            let card = DetailRelatedCard(item: session)
            return CardItem(id: session.entryID, artwork: card.posterPath.map { .path($0, .poster) },
                            title: session.mediaType == "episode" ? (session.grandparentTitle ?? session.title) : session.title,
                            subtitle: ServerActivity.subtitle(session), progress: card.progress,
                            placeholderSymbol: card.isShow || session.mediaType == "episode" ? "tv" : "film").linked(to: session)
        }
        grid.refreshInterval = .seconds(10)
        grid.liveRefresh = { $0.isPlayback }
        grid.summary = { items in items.count == 1 ? String(localized: "1 stream") : String(localized: "\(items.count) streams") }
        grid.onMenu = { [weak grid] session, point in
            guard let grid else { return }
            var extras: [(item: MenuView.Item, run: () -> Void)] = []
            if ServerOwnership.isOwner(), let id = ServerActivity.stoppableSessionID(session) {
                extras.append((MenuView.Item(id: "stop", title: ManageCopy.stopStream, symbol: "stop.circle", isDestructive: true), { [weak grid] in
                    guard let grid else { return }
                    presentStopReasons(sessionID: id, api: api, in: grid)
                }))
            }
            ItemActions.present(for: session, api: api, at: point, in: grid, extras: extras) { [weak grid] in grid?.reload() }
        }
        return grid
    }

    /// Stop Stream's reasons, each ending the stream with that note to the viewer.
    private static func presentStopReasons(sessionID: String, api: APIClient, in grid: TitleGridScreen) {
        guard let window = grid.window else { return }
        let frame = window.focusedView?.frameInWindow ?? grid.frameInWindow
        let menu = MenuView(title: ManageCopy.stopStream, items: ManageCopy.stopReasons.enumerated().map {
            MenuView.Item(id: String($0.offset), title: $0.element, isDestructive: true)
        }, anchor: Rect(x: frame.minX, y: frame.maxY, width: 1, height: 1))
        menu.onSelect = { [weak grid] item in
            guard let index = Int(item.id), ManageCopy.stopReasons.indices.contains(index) else { return }
            let reason = ManageCopy.stopReasons[index]
            Task { [weak grid] in
                do {
                    try await LibraryManagement.stopStream(sessionId: sessionID, reason: reason, api: api)
                } catch {
                    if let window = grid?.window { AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window) }
                }
                grid?.reload()
            }
        }
        menu.present(in: window)
    }
}

/// The owner's server dashboard: how hard the server works, the jobs it runs (each cancellable), its version and a waiting
/// update with its release notes. Refreshes every five seconds while open, and at once when a job moves on.
@MainActor
final class ServerDashboardScreen: SettingsScaffold {
    private enum RowID {
        static let load = "dashboard.load"
        static let idle = "dashboard.idle"
        static let version = "dashboard.version"
        static let update = "dashboard.update"
        static let check = "dashboard.check"
        static let activityPrefix = "dashboard.activity."
    }

    private let api: APIClient
    private var sample: PlexResourceSample?
    private var activities: [PlexActivity] = []
    private var release: PlexServerRelease?
    private var version: String?
    private var pollTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        super.init(title: ServerDashboardCopy.title,
                   detail: String(localized: "What your server is doing right now.", comment: "Explanation under the server dashboard's title"))
        render()
    }

    override func screenDidAppear() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        let api = api
        liveTask = Task { [weak self] in
            await ServerEventHub.shared.listen(api: api, every: .seconds(1), matching: { $0.isActivity }) {
                Task { await self?.refresh() }
            }.hold()
        }
    }

    override func screenWillDisappear() {
        pollTask?.cancel()
        liveTask?.cancel()
    }

    override func rowSelected(_ id: String) {
        let api = api
        switch id {
        case RowID.check:
            run { [weak self] in
                try await LibraryManagement.checkForUpdates(api: api)
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
        case RowID.update:
            showRelease()
        default:
            guard id.hasPrefix(RowID.activityPrefix), let activity = activities.first(where: { RowID.activityPrefix + $0.uuid == id }) else { return }
            cancel(activity)
        }
    }

    private func refresh() async {
        let api = api
        async let sample = try? LibraryManagement.load(api: api)
        async let activities = try? LibraryManagement.activities(api: api)
        async let release = try? LibraryManagement.availableUpdate(api: api)
        async let identity: PlexIdentity? = try? api.request(.identity)
        let loaded = await (sample, activities, release, identity)
        self.sample = loaded.0 ?? nil
        self.activities = loaded.1 ?? []
        self.release = loaded.2 ?? nil
        version = loaded.3?.MediaContainer.version ?? version
        render()
    }

    private func render() {
        var items = [RowItem(id: RowID.load, title: String(localized: "Load", comment: "Server dashboard row for CPU and memory use"),
                             value: ServerDashboardCopy.loadText(sample), symbol: "gauge.with.dots.needle.33percent", isStatic: true)]
        if activities.isEmpty {
            items.append(RowItem(id: RowID.idle, title: String(localized: "Nothing running", comment: "Server dashboard: the server has no background tasks"),
                                 symbol: "checkmark.circle", isStatic: true))
        } else {
            items += activities.map { activity in
                RowItem(id: RowID.activityPrefix + activity.uuid, title: activity.title ?? "", subtitle: activity.subtitle,
                        value: activity.progress.map { "\($0)%" }, symbol: "gearshape.2", isStatic: activity.cancellable != true)
            }
        }
        items.append(RowItem(id: RowID.version, title: String(localized: "Plex Media Server", comment: "Server dashboard row showing the server version"),
                             value: version, symbol: "server.rack", isStatic: true))
        if let release {
            items.append(RowItem(id: RowID.update, title: String(localized: "Update Available", comment: "Server dashboard row when a server update is waiting"),
                                 value: release.version, symbol: "arrow.down.app", accessory: .chevron))
        }
        items.append(RowItem(id: RowID.check, title: String(localized: "Check for Updates", comment: "Server dashboard action"), symbol: "arrow.clockwise"))
        setRows(items)
    }

    private func cancel(_ activity: PlexActivity) {
        guard activity.cancellable == true, let window else { return }
        let api = api
        AlertView.confirm(title: activity.title ?? "", message: String(localized: "Stops this task on your server.", comment: "Confirmation message for cancelling a server task"),
                          confirm: String(localized: "Cancel Task", comment: "Button that cancels a server task"), in: window) { [weak self] in
            self?.run {
                try await LibraryManagement.cancel(activity, api: api)
                await self?.refresh()
            }
        }
    }

    private func showRelease() {
        guard let release, let window else { return }
        let api = api
        AlertView(title: ServerDashboardCopy.releaseTitle(release), message: ServerDashboardCopy.releaseNotes(release), actions: [
            AlertView.Action(String(localized: "Install Now", comment: "Button that installs a server update")) { [weak self] in
                self?.run { try await LibraryManagement.installUpdate(api: api) }
            },
            AlertView.Action(String(localized: "Later", comment: "Button that leaves a server update for later"), role: .cancel),
        ]).present(in: window)
    }

    /// Runs an owner tool; a refusal says so in an alert.
    private func run(_ work: @escaping () async throws -> Void) {
        Task { [weak self] in
            do {
                try await work()
            } catch {
                guard let window = self?.window else { return }
                AlertView.notice(title: ManageCopy.failed, message: ConnectionError.message(for: error), in: window)
            }
        }
    }
}

/// The members of the account's Plex Home (`TVProfilesViewController`), the one watching now ticked. Select asks for a
/// profile's PIN when it has one, then the app starts over as that profile; the account's own sign-in stays as it was.
@MainActor
final class ProfilesScreen: SettingsScaffold {
    private static let prefix = "profiles."

    private let machineIdentifier: String
    private let onSwitched: () -> Void
    private let state = StateView()
    private var profiles: [HomeProfile] = []
    private var accountID: String?
    private var switchingID: String?
    private var loadTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?

    init(machineIdentifier: String, onSwitched: @escaping () -> Void) {
        self.machineIdentifier = machineIdentifier
        self.onSwitched = onSwitched
        super.init(title: HomeProfiles.title,
                   detail: String(localized: "Each profile has its own Continue Watching, watched titles, ratings and watchlist.",
                                  comment: "Explanation beside the Plex Home profile list on Apple TV"))
        addSubview(state)
        showState(.loading(title: nil))
    }

    override var preferredFocusView: View? { state.isHidden ? rows : state }

    private var currentID: String? { HomeProfiles.active?.id ?? accountID }

    override func screenDidAppear() {
        if profiles.isEmpty { load() }
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    override func rowSelected(_ id: String) {
        guard switchingID == nil, let profile = profiles.first(where: { Self.prefix + $0.id == id }), profile.id != currentID else { return }
        if profile.isProtected {
            askForPIN(for: profile)
        } else {
            switchTo(profile, pin: nil)
        }
    }

    private func load() {
        guard let token = ServerBootstrap.accountToken else {
            showState(.error(title: String(localized: "Couldn’t Load Profiles"), message: nil, retryTitle: String(localized: "Try Again"),
                             retry: { [weak self] in self?.load() }))
            return
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let loaded = try await HomeProfiles.load(accountToken: token)
                guard let self, !Task.isCancelled else { return }
                self.profiles = loaded.profiles
                self.accountID = loaded.accountID
                if self.profiles.isEmpty {
                    self.showState(.empty(title: String(localized: "No Other Profiles", comment: "Title when the account has no Plex Home profiles"),
                                          message: String(localized: "Profiles for the people you live with are set up in Plex, under Plex Home.",
                                                          comment: "Explanation when the account has no Plex Home profiles"),
                                          symbol: "person.2", action: nil))
                } else {
                    self.render()
                    self.hideState()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                MidgarLog.error("Home profiles failed to load: \(error)", category: .networking)
                self.showState(.error(title: String(localized: "Couldn’t Load Profiles"), message: ConnectionError.message(for: error),
                                      retryTitle: String(localized: "Try Again"), retry: { [weak self] in
                                          self?.showState(.loading(title: nil))
                                          self?.load()
                                      }))
            }
        }
    }

    private func render() {
        setRows(profiles.map { profile in
            RowItem(id: Self.prefix + profile.id, title: profile.title, subtitle: profile.detail,
                    value: profile.id == switchingID ? String(localized: "Switching…", comment: "Shown beside a Plex Home profile while switching to it") : nil,
                    symbol: profile.isProtected && profile.id != currentID ? "lock.fill" : (profile.isRestricted ? "figure.and.child.holdinghands" : "person.crop.circle"),
                    accessory: profile.id == currentID ? .checkmark : .none)
        })
    }

    /// The four-digit PIN of a protected profile, typed in a field that shows dots.
    private func askForPIN(for profile: HomeProfile, after error: String? = nil) {
        guard let window else { return }
        weak var alert: AlertView?
        let shown = AlertView(title: String(localized: "Enter PIN for \(profile.title)", comment: "Title of the PIN prompt for a Plex Home profile"),
                              message: error, actions: [
                                AlertView.Action(String(localized: "Switch", comment: "Button that switches to a Plex Home profile")) { [weak self] in
                                    self?.switchTo(profile, pin: alert?.text ?? "")
                                },
                                AlertView.Action(String(localized: "Cancel"), role: .cancel),
                              ], fieldPlaceholder: String(localized: "PIN"), secureField: true)
        alert = shown
        shown.present(in: window)
    }

    private func switchTo(_ profile: HomeProfile, pin: String?) {
        guard let token = ServerBootstrap.accountToken else { return }
        switchingID = profile.id
        render()
        let isAccount = profile.id == accountID
        let machine = machineIdentifier
        switchTask = Task { [weak self] in
            do {
                try await HomeProfiles.switchTo(profile, pin: pin, isAccount: isAccount, accountToken: token, machineIdentifier: machine)
                AccountSessionReset.switchedProfile(LinuxSession.collaborators)
                self?.onSwitched()
            } catch {
                guard let self else { return }
                self.switchingID = nil
                self.render()
                if case HomeProfiles.SwitchError.wrongPIN = error {
                    self.askForPIN(for: profile, after: error.localizedDescription)
                } else if let window = self.window {
                    MidgarLog.error("Switching Home profile failed: \(error)", category: .networking)
                    AlertView.notice(title: String(localized: "Couldn’t Switch Profile"), message: ConnectionError.message(for: error), in: window)
                }
            }
        }
    }

    private func showState(_ newState: StateView.State) {
        state.show(newState)
        state.isHidden = false
        rows.isHidden = true
        if containsFocus || window?.focusedView == nil { window?.focus.focus(state, animated: false) }
    }

    private func hideState() {
        let hadFocus = state.containsFocus
        state.isHidden = true
        rows.isHidden = false
        if hadFocus { window?.focus.focus(rows, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        state.frame = bounds
    }
}
