import CrucibleCore
import CrucibleDesign
import UIKit

/// Sports Research on Apple TV: the pitch in the context column, every requirement as a row whose explanation fills
/// the column while it has the focus, the owner's choices, what the server is doing, and what it made of each file.
final class TVSportsResearchViewController: TVSettingsScaffold {
    private enum ID {
        static let summary = "sports.summary"
        static let switchedOn = "sports.on"
        static let agreement = "sports.agreement"
        static let checkAgain = "sports.checkAgain"
        static let lookNow = "sports.lookNow"
        static let now = "sports.now"
        static let nothingYet = "sports.nothingYet"
        static let check = "sports.check."
        static let library = "sports.library."
        static let item = "sports.item."
    }

    private let source: any SportsSource
    private let heading = TVSettingsHeading(title: SportsCopy.title, body: "\(SportsCopy.pitch)\n\n\(SportsCopy.forWhom)")
    private var board: SportsBoard?
    private var busy = false
    private var refreshTask: Task<Void, Never>?

    init(source: any SportsSource) {
        self.source = source
        super.init()
        title = SportsCopy.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        presentState(.loading(title: SportsCopy.title))
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        startRefreshing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Starts the polling again after an action, unless the screen was left while the action ran.
    private func resumeRefreshingIfShown() {
        guard viewIfLoaded?.window != nil else { return }
        startRefreshing()
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                let working = self?.board?.report.status.isWorking ?? false
                try? await Task.sleep(for: .seconds(working ? 3 : 30))
            }
        }
    }

    private func load() async {
        do throws(CompanionError) {
            board = SportsBoard(report: try await source.sports())
            presentState(nil)
            render()
        } catch {
            let message = SportsCopy.failure(error, hasSports: await source.hasSports())
            guard board == nil else {
                heading.setBody(message)
                return
            }
            presentState(.error(title: SportsCopy.title, message: message, retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.startRefreshing() }, secondary: nil))
        }
    }

    private func render() {
        guard let board else { return }
        let report = board.report
        let done = board.doneCount == board.total
        var rows = [TVRowItem(
            id: ID.summary,
            title: done ? SportsCopy.allReady : SportsCopy.progress(done: board.doneCount, of: board.total),
            subtitle: [SportsCopy.phase(report.status), report.status.current?.name].compactMap { $0 }.joined(separator: " · "),
            symbol: done ? "checkmark.seal.fill" : "sportscourt"
        )]
        for (_, checks) in board.groups {
            rows += checks.map { check in
                TVRowItem(id: ID.check + check.id, title: SportsCopy.title(check.requirement ?? .model), subtitle: check.state == .done ? nil : check.settledInApp(in: report) ? SportsCopy.belowInChoices : check.detail, value: check.state == .done ? nil : SportsCopy.state(check.state), symbol: symbol(check.state))
            }
        }
        if report.owner {
            rows.append(TVRowItem(id: ID.switchedOn, title: SportsCopy.researchNewFiles, value: report.settings.on ? String(localized: "On") : String(localized: "Off"), symbol: "power", isEnabled: !busy))
            rows += report.libraries.map { library in
                TVRowItem(id: ID.library + library.key, title: library.title, value: library.chosen ? String(localized: "On") : String(localized: "Off"), symbol: "film.stack", isEnabled: !busy)
            }
            if report.settings.destination != nil {
                rows.append(TVRowItem(id: ID.agreement, title: report.settings.agreed ? SportsCopy.withdraw : SportsCopy.agree, symbol: report.settings.agreed ? "hand.thumbsup.fill" : "hand.raised", isEnabled: !busy))
            }
            rows.append(TVRowItem(id: ID.checkAgain, title: SportsCopy.checkAgain, subtitle: busy ? CompanionCopy.checking : nil, symbol: "arrow.triangle.2.circlepath", isEnabled: !busy))
            rows.append(TVRowItem(id: ID.lookNow, title: SportsCopy.lookNow, symbol: "magnifyingglass", isEnabled: !busy))
        }
        rows.append(TVRowItem(id: ID.now, title: SportsCopy.phase(report.status), subtitle: nowDetail(report.status), symbol: report.status.isWorking ? "waveform" : "clock"))
        let items = board.items
        if items.isEmpty {
            rows.append(TVRowItem(id: ID.nothingYet, title: SportsCopy.nothingYet, symbol: "tray", isStatic: true))
        } else {
            rows += items.map { item in
                TVRowItem(id: ID.item + item.ratingKey, title: SportsItemLabel.title(item), subtitle: [SportsCopy.itemState(item.state), item.note].filter { !$0.isEmpty }.joined(separator: " · "), symbol: SportsCopy.itemSymbol(item.state))
            }
        }
        setRows(rows)
    }

    private func symbol(_ state: SportsCheck.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .missing: "circle.dashed"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func nowDetail(_ status: SportsStatus) -> String? {
        var parts: [String] = []
        if let current = status.current, status.isWorking { parts.append("\(current.name) · \(current.step)") }
        if status.queued > 0 { parts.append(SportsCopy.queued(status.queued)) }
        if let last = status.lastPass { parts.append(SportsCopy.lastLooked(Date(timeIntervalSince1970: TimeInterval(last)))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The context column explains the focused row: why a requirement matters, where it stands and how to meet it.
    override func rowDidFocus(_ id: String?) {
        guard let id, let board else { return }
        if id.hasPrefix(ID.check), let check = board.report.checks.first(where: { ID.check + $0.id == id }), let requirement = check.requirement {
            var lines = [SportsCopy.why(requirement)]
            if check.settledInApp(in: board.report) {
                lines.append(SportsCopy.belowInChoices)
            } else if check.state != .done {
                lines.append(check.detail)
                if let fix = check.fix { lines.append(fix) }
            }
            heading.setBody(lines.joined(separator: "\n\n"))
        } else if id == ID.agreement, let destination = board.report.settings.destination {
            heading.setBody(SportsCopy.agreeQuestion(destination))
        } else if id == ID.switchedOn {
            heading.setBody(SportsCopy.why(.on))
        } else if id.hasPrefix(ID.library) {
            heading.setBody(SportsCopy.why(.libraries))
        } else if id.hasPrefix(ID.item), let item = board.report.items.first(where: { ID.item + $0.ratingKey == id }) {
            heading.setBody([item.title, item.fileName, item.note].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        } else {
            heading.setBody("\(SportsCopy.pitch)\n\n\(board.report.owner ? SportsCopy.forWhom : SportsCopy.ownerOnly)")
        }
    }

    override func rowDidSelect(_ id: String) {
        guard let report = board?.report, report.owner else { return }
        switch id {
        case ID.switchedOn: setOn(!report.settings.on)
        case ID.agreement: report.settings.agreed ? change(agree: false) : askToAgree()
        case ID.checkAgain: perform { source throws(CompanionError) in try await source.recheckSports() }
        case ID.lookNow: perform { source throws(CompanionError) in try await source.runSports() }
        case _ where id.hasPrefix(ID.library):
            let key = String(id.dropFirst(ID.library.count))
            var chosen = report.libraries.filter(\.chosen).map(\.key)
            if chosen.contains(key) { chosen.removeAll { $0 == key } } else { chosen.append(key) }
            change(libraries: chosen)
        case _ where id.hasPrefix(ID.item):
            let key = String(id.dropFirst(ID.item.count))
            presentConfirmation(title: SportsCopy.researchAgain, message: report.items.first { $0.ratingKey == key }?.fileName, confirmTitle: SportsCopy.researchAgain) { [weak self] in
                self?.perform { source throws(CompanionError) in try await source.redoSports(ratingKey: key) }
            }
        case _ where id.hasPrefix(ID.check):
            if id == ID.check + SportsRequirement.agreement.rawValue { askToAgree() }
        default: break
        }
    }

    /// Turning research on is part of Crucible Pro; turning it off never is.
    private func setOn(_ wanted: Bool) {
        guard wanted else { return change(on: false) }
        ProAccess.shared.requestUnlock(.sportsResearch) { [weak self] unlocked in
            if unlocked { self?.change(on: true) }
        }
    }

    private func askToAgree() {
        guard let destination = board?.report.settings.destination else { return }
        presentConfirmation(title: SportsCopy.title(.agreement), message: SportsCopy.agreeQuestion(destination), confirmTitle: SportsCopy.agree) { [weak self] in
            self?.change(agree: true)
        }
    }

    private func change(on: Bool? = nil, libraries: [String]? = nil, agree: Bool? = nil) {
        if let board { self.board = SportsBoard(report: board.report.expecting(on: on, libraries: libraries, agree: agree)) }
        perform { source throws(CompanionError) in try await source.changeSports(on: on, libraries: libraries, agree: agree) }
    }

    private func perform(_ action: @escaping @Sendable (any SportsSource) async throws(CompanionError) -> Void) {
        guard !busy else { return }
        busy = true
        render()
        Task { [weak self, source] in
            do throws(CompanionError) {
                try await action(source)
            } catch {
                self?.heading.setBody(error.message)
            }
            self?.busy = false
            await self?.load()
            self?.resumeRefreshingIfShown()
        }
    }
}
