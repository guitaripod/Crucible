import CrucibleCore
import CrucibleDesign
import UIKit

/// The viewer's Seerr requests on Apple TV; whoever approves requests also sees everyone's and decides on them from the
/// couch, which is part of Crucible Pro.
final class TVSeerrRequestsViewController: TVSettingsScaffold {
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

    private let env: TVAppEnvironment
    private let heading = TVSettingsHeading(title: SeerrCopy.requests)
    private var entries: [SeerrRequestEntry] = []
    private var filter = Filter.mine
    private var loaded = false
    private lazy var loadSlot = makeTaskSlot()
    nonisolated(unsafe) private var changeObserver: (any NSObjectProtocol)?

    init(env: TVAppEnvironment) {
        self.env = env
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        heading.setBody(SeerrAccount.shared.connection?.displayName)
        render()
        reload()
        changeObserver = NotificationCenter.default.addObserver(forName: .seerrRequestsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    override var preferredFocusRowID: String? {
        entries.first.map { "seerr.requests.\($0.id)" }
    }

    /// Loads the list for the current filter; a newer load cancels an older one, so a slow answer never replaces a newer list.
    private func reload() {
        let scope: SeerrRequests.Scope = filter == .mine ? .mine : .everyone
        let pendingOnly = filter == .awaiting
        if !loaded { presentState(.loading(title: nil)) }
        loadSlot.run { [weak self] in
            do {
                let entries = try await SeerrRequests.shared.load(scope: scope, pendingOnly: pendingOnly)
                guard !Task.isCancelled, let self else { return }
                self.entries = entries
                loaded = true
                presentState(nil)
                render()
            } catch {
                guard !Task.isCancelled, let self else { return }
                entries = []
                loaded = true
                presentState(.error(
                    title: String(localized: "Couldn\u{2019}t Load"),
                    message: error.localizedDescription,
                    retryTitle: String(localized: "Try Again"),
                    retry: { [weak self] in self?.reload() }
                ))
            }
        }
    }

    private func render() {
        var rows: [TVRowItem] = []
        if SeerrAccount.shared.managesRequests {
            rows.append(TVRowItem(id: "seerr.requests.filter", title: String(localized: "Show", comment: "Apple TV row that switches which Seerr requests are listed"), value: filter.title, symbol: "line.3.horizontal.decrease.circle", accessory: .chevron))
        }
        if loaded, entries.isEmpty {
            rows.append(TVRowItem(id: "seerr.requests.empty", title: SeerrCopy.noRequestsTitle, subtitle: SeerrCopy.noRequestsText, symbol: "tray", isStatic: true))
        }
        for entry in entries {
            var lines = [[SeerrCopy.label(entry.availability), entry.seasonsLabel].compactMap { $0 }.joined(separator: " · ")]
            if let detail = SeerrCopy.detail(entry.availability) { lines.append(detail) }
            if !entry.isMine, let name = entry.request.requestedBy?.name { lines.append(SeerrCopy.requestedBy(name)) }
            let hasActions = entry.ratingKey != nil || !actions(for: entry).isEmpty
            rows.append(TVRowItem(
                id: "seerr.requests.\(entry.id)",
                title: [entry.title, entry.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                subtitle: lines.joined(separator: " · "),
                symbol: SeerrCopy.symbol(entry.availability),
                accessory: hasActions ? .chevron : .none,
                isStatic: !hasActions
            ))
        }
        setRows(rows)
    }

    private struct RequestAction {
        let title: String
        let isDestructive: Bool
        let run: @MainActor () -> Void
    }

    private func actions(for entry: SeerrRequestEntry) -> [RequestAction] {
        var actions: [RequestAction] = []
        let manages = SeerrAccount.shared.managesRequests
        if manages, entry.request.requestStatus == .pending {
            actions.append(RequestAction(title: SeerrCopy.approve, isDestructive: false) { [weak self] in self?.decide(entry, approve: true) })
            actions.append(RequestAction(title: SeerrCopy.decline, isDestructive: true) { [weak self] in self?.decide(entry, approve: false) })
        } else if manages, entry.request.requestStatus == .failed {
            actions.append(RequestAction(title: SeerrCopy.retry, isDestructive: false) { [weak self] in self?.retry(entry) })
        }
        if (entry.isMine && entry.request.requestStatus == .pending) || manages {
            let title = entry.isMine && entry.request.requestStatus == .pending ? SeerrCopy.withdraw : SeerrCopy.remove
            actions.append(RequestAction(title: title, isDestructive: true) { [weak self] in self?.run { try await SeerrRequests.shared.remove(entry) } })
        }
        return actions
    }

    override func rowDidSelect(_ id: String) {
        if id == "seerr.requests.filter" {
            filter = Filter(rawValue: (filter.rawValue + 1) % Filter.allCases.count) ?? .mine
            entries = []
            loaded = false
            render()
            reload()
            return
        }
        guard id.hasPrefix("seerr.requests."), let number = Int(id.dropFirst("seerr.requests.".count)),
              let entry = entries.first(where: { $0.id == number }), presentedViewController == nil else { return }
        let alert = UIAlertController(title: entry.title, message: SeerrCopy.label(entry.availability), preferredStyle: .alert)
        if let ratingKey = entry.ratingKey {
            alert.addAction(UIAlertAction(title: SeerrCopy.play, style: .default) { [weak self] _ in self?.open(ratingKey) })
        }
        for action in actions(for: entry) {
            alert.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) { _ in action.run() })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: TVMotion.animationsEnabled)
    }

    private func open(_ ratingKey: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let item = try await env.api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first else { return }
                TVHomeActions(env: env, onChange: {}).openDetail(item, from: self)
            } catch {
                presentAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }

    private func decide(_ entry: SeerrRequestEntry, approve: Bool) {
        ProAccess.shared.requestUnlock(.manageRequests) { [weak self] unlocked in
            guard unlocked else { return }
            self?.run { try await SeerrRequests.shared.decide(entry, approve: approve) }
        }
    }

    private func retry(_ entry: SeerrRequestEntry) {
        ProAccess.shared.requestUnlock(.manageRequests) { [weak self] unlocked in
            guard unlocked else { return }
            self?.run { try await SeerrRequests.shared.retry(entry) }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            do {
                try await work()
            } catch {
                self?.presentAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }
}
