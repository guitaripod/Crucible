import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// Request on Apple TV: a title the server does not have, or a show missing seasons, where it stands in Seerr, the seasons
/// to ask for and the Request button. Requesting a title the server does not have also puts it on the Plex watchlist.
final class TVSeerrRequestViewController: TVSettingsScaffold {
    private let env: TVAppEnvironment
    private let item: PlexMetadata
    private let isOnServer: Bool
    private let heading: TVSettingsHeading
    private var state: SeerrTitleState?
    private var failure: String?
    private var selected = Set<Int>()
    private var isWorking = false
    private var addedToWatchlist = false
    private var hasRequested = false

    init(env: TVAppEnvironment, item: PlexMetadata, isOnServer: Bool) {
        self.env = env
        self.item = item
        self.isOnServer = isOnServer
        heading = TVSettingsHeading(title: item.title)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens Request for `item`, or says how to set requests up when Seerr is not connected.
    static func open(_ item: PlexMetadata, env: TVAppEnvironment, isOnServer: Bool, from screen: UIViewController) {
        guard SeerrAccount.shared.isConnected else {
            let message = isOnServer ? SeerrCopy.notConnectedMessage : WatchlistService.notInLibraryText + "\n\n" + SeerrCopy.notConnectedMessage
            guard screen.presentedViewController == nil else { return }
            let alert = UIAlertController(title: isOnServer ? SeerrCopy.notConnectedTitle : WatchlistService.notInLibraryTitle, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: SeerrCopy.setUp, style: .default) { [weak screen] _ in
                guard let screen else { return }
                TVNavigation.push(TVSeerrSettingsViewController(env: env), from: screen)
            })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
            screen.present(alert, animated: TVMotion.animationsEnabled)
            return
        }
        TVNavigation.push(TVSeerrRequestViewController(env: env, item: item, isOnServer: isOnServer), from: screen)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        render()
        load()
    }

    override var preferredFocusRowID: String? {
        guard let state else { return nil }
        if hasRequested { return showsPlay ? "seerr.request.play" : "seerr.request.requests" }
        if state.canRequest(with: SeerrAccount.shared.permissions) { return "seerr.request.submit" }
        if state.ownPendingRequest != nil { return "seerr.request.withdraw" }
        return showsPlay ? "seerr.request.play" : nil
    }

    private func load(refresh: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let found = try await SeerrTitles.shared.state(for: item, api: isOnServer ? env.api : nil, refresh: refresh) else {
                    failure = SeerrCopy.notIdentified
                    return render()
                }
                state = found
                failure = nil
                selected = Set(found.requestableSeasons)
            } catch {
                failure = error.localizedDescription
            }
            render()
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
            bodyParts.append([year.map(String.init), SeerrCopy.label(state.availability), SeerrCopy.detail(state.availability)].compactMap { $0 }.joined(separator: " · "))
        } else if let year {
            bodyParts.append(String(year))
        }
        if let overview = state?.overview ?? item.summary, !overview.isEmpty { bodyParts.append(overview) }
        heading.setBody(bodyParts.joined(separator: "\n\n"))

        var rows: [TVRowItem] = []
        if let failure {
            rows.append(TVRowItem(id: "seerr.request.message", title: failure, symbol: "info.circle", isStatic: true))
        } else if let state {
            if showsPlay { rows.append(TVRowItem(id: "seerr.request.play", title: SeerrCopy.play, symbol: "play.fill", accessory: .chevron)) }
            if state.canRequest(with: SeerrAccount.shared.permissions) {
                rows.append(TVRowItem(id: "seerr.request.submit", title: isWorking ? SeerrCopy.connecting : requestTitle, symbol: "plus.circle", isEnabled: canSubmit))
            } else if !SeerrAccount.shared.permissions.canRequest(state.kind), state.availability == .notRequested {
                rows.append(TVRowItem(id: "seerr.request.message", title: SeerrError.notAllowed.localizedDescription, symbol: "info.circle", isStatic: true))
            }
            if state.ownPendingRequest != nil {
                rows.append(TVRowItem(id: "seerr.request.withdraw", title: SeerrCopy.withdraw, symbol: "xmark.circle", isDestructive: true))
            }
            if hasRequested {
                rows.append(TVRowItem(id: "seerr.request.requests", title: SeerrCopy.seeRequests, symbol: "tray.full", accessory: .chevron))
            }
            if addedToWatchlist {
                rows.append(TVRowItem(id: "seerr.request.watchlisted", title: SeerrCopy.alsoWatchlist, symbol: "bookmark", isStatic: true))
            }
            if state.kind == .tv, !partial, !state.requestableSeasons.isEmpty {
                rows.append(TVRowItem(id: "seerr.request.allSeasons", title: SeerrCopy.onlyAllSeasons, symbol: "info.circle", isStatic: true))
            }
            for season in state.seasons {
                let requestable = season.status == .missing
                let chosen = requestable && (selected.contains(season.number) || !partial)
                rows.append(TVRowItem(
                    id: "seerr.season.\(season.number)",
                    title: SeerrCopy.seasonName(season),
                    subtitle: [SeerrCopy.seasonStatus(season.status), season.episodeCount.map { String(localized: "\($0) episodes", comment: "Number of episodes in a season") }].compactMap { $0 }.joined(separator: " · "),
                    symbol: requestable ? (chosen ? "checkmark.circle.fill" : "circle") : (season.status == .available ? "play.circle" : "arrow.down.circle"),
                    accessory: chosen ? .checkmark : .none,
                    isStatic: !requestable || !partial
                ))
            }
        } else {
            rows.append(TVRowItem(id: "seerr.request.loading", title: SeerrCopy.connecting, symbol: "tray.and.arrow.down", isStatic: true))
        }
        setRows(rows)
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

    override func rowDidSelect(_ id: String) {
        switch id {
        case "seerr.request.submit": submit()
        case "seerr.request.withdraw": withdraw()
        case "seerr.request.play": play()
        case "seerr.request.requests": TVNavigation.push(TVSeerrRequestsViewController(env: env), from: self)
        default:
            guard id.hasPrefix("seerr.season."), partial, let number = Int(id.dropFirst("seerr.season.".count)),
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
            guard let self else { return }
            do {
                self.state = try await SeerrTitles.shared.request(state, seasons: seasons)
                selected = Set(self.state?.requestableSeasons ?? [])
                hasRequested = true
                if !isOnServer, let guid = item.guid { await addToWatchlist(guid) }
            } catch {
                presentAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
            isWorking = false
            render()
        }
    }

    private func addToWatchlist(_ guid: String) async {
        let token = env.api.token
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
            guard let self else { return }
            do {
                self.state = try await SeerrTitles.shared.withdraw(request, of: state)
                selected = Set(self.state?.requestableSeasons ?? [])
            } catch {
                presentAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
            isWorking = false
            render()
        }
    }

    private func play() {
        guard let ratingKey = state?.ratingKey else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let local = try await env.api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first else { return }
                TVHomeActions(env: env, onChange: {}).openDetail(local, from: self)
            } catch {
                presentAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }
}
