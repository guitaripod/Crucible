import CrucibleCore
import CrucibleDesign
import UIKit

/// Sports Research on Apple TV. The rows on the right are what someone can do or look at: where setup stands, the research
/// running now, the four setup steps, the owner's choices and every researched file. The stage on the left shows whatever
/// has the focus: the newest result or an example, the live research ticking, a step's checks, or a file's poster, card and
/// new title.
final class TVSportsResearchViewController: TVSettingsScaffold {
    private enum ID {
        static let unreachable = "sports.unreachable"
        static let summary = "sports.summary"
        static let live = "sports.live"
        static let step = "sports.step."
        static let how = "sports.how."
        static let switchedOn = "sports.on"
        static let agreement = "sports.agreement"
        static let checkAgain = "sports.checkAgain"
        static let lookNow = "sports.lookNow"
        static let results = "sports.results"
        static let nothingYet = "sports.nothingYet"
        static let library = "sports.library."
        static let item = "sports.item."
    }

    private let source: any SportsSource
    private let stage = TVSportsStage(title: SportsCopy.title)
    private var board: SportsBoard?
    private var receivedAt = Date()
    private var failure: String?
    private var busy = false
    private var refreshTask: Task<Void, Never>?
    private var focusedID: String?

    private var mode: SportsMode? { board?.mode(isPro: ProAccess.shared.hasFullAccess) }

    init(source: any SportsSource) {
        self.source = source
        super.init()
        title = SportsCopy.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContext(stage)
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

    /// Asks the server now and again while the screen shows: every few seconds while it works, else every half minute,
    /// backing off while it does not answer.
    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !busy { await load() }
                let working = board?.report.status.isWorking == true || (board?.report.status.queued ?? 0) > 0
                let wait: Double = failure != nil ? 15 : working ? 3 : 30
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func load() async {
        do throws(CompanionError) {
            let report = try await source.sports()
            guard !busy else { return }
            board = SportsBoard(report: report)
            receivedAt = Date()
            failure = nil
            presentState(nil)
            render()
        } catch {
            guard !Task.isCancelled, !busy else { return }
            let message = SportsCopy.failure(error, hasSports: await source.hasSports())
            failure = message
            guard board == nil else { return render() }
            presentState(.error(title: SportsCopy.title, message: message, retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.startRefreshing() }, secondary: nil))
        }
    }

    /// Starts the polling again after an action, unless the screen was left while the action ran.
    private func resumeRefreshingIfShown() {
        guard viewIfLoaded?.window != nil else { return }
        startRefreshing()
    }

    override var preferredFocusRowID: String? {
        guard let board, let mode else { return nil }
        if mode == .setup, let step = board.firstOpenStep { return ID.step + "\(step.number)" }
        if board.report.status.isWorking, board.report.status.current != nil { return ID.live }
        return nil
    }

    // MARK: Rows

    private func render() {
        guard let board, let mode else { return }
        let report = board.report
        var rows: [TVRowItem] = []
        if let failure {
            rows.append(TVRowItem(id: ID.unreachable, title: SportsCopy.unreachableTitle, subtitle: failure == SportsCopy.updateServer ? failure : SportsCopy.unreachableBody, symbol: "wifi.exclamationmark"))
        }
        rows.append(summaryRow(board, mode))
        if failure == nil, report.status.isWorking, let current = report.status.current {
            rows.append(TVRowItem(id: ID.live, title: SportsCopy.phase(report.status), subtitle: current.name, value: report.status.queued > 0 ? SportsCopy.queued(report.status.queued) : nil, symbol: "waveform"))
        }
        switch mode {
        case .notPro:
            rows += SportsCopy.howSteps.enumerated().map { index, step in
                TVRowItem(id: ID.how + "\(index)", title: step.title, subtitle: step.detail, symbol: step.symbol, isStatic: true)
            }
        case .viewer:
            break
        case .setup, .onlySwitch:
            rows += board.steps.map { stepRow($0, total: board.steps.count) }
            rows += choiceRows(report)
        case .ready:
            rows += choiceRows(report)
        }
        let items = board.items
        if !items.isEmpty {
            rows.append(TVRowItem(id: ID.results, title: SportsCopy.resultsHeader, value: SportsCopy.counts(board), symbol: "square.grid.2x2", isStatic: true))
            rows += items.map { item in
                TVRowItem(id: ID.item + item.ratingKey, title: SportsItemLabel.title(item), subtitle: SportsCopy.meta(item), value: item.state == "matched" ? nil : SportsCopy.itemState(item.state), symbol: SportsCopy.itemSymbol(item.state))
            }
        } else if mode == .ready {
            rows.append(TVRowItem(id: ID.nothingYet, title: SportsCopy.nothingYet, symbol: "tray", isStatic: true))
        }
        setRows(rows)
        refreshStage()
    }

    private func summaryRow(_ board: SportsBoard, _ mode: SportsMode) -> TVRowItem {
        let status = board.report.status
        let progress = SportsCopy.progress(done: board.doneCount, of: board.total)
        switch mode {
        case .notPro:
            return TVRowItem(id: ID.summary, title: SportsCopy.proPitch, subtitle: SportsCopy.seePro, symbol: "lock.fill", accessory: .chevron)
        case .viewer:
            return TVRowItem(id: ID.summary, title: SportsCopy.phase(status), subtitle: SportsCopy.ownerOnly, symbol: "eye")
        case .setup:
            return TVRowItem(id: ID.summary, title: SportsCopy.setUpInFour, subtitle: progress, symbol: "list.number")
        case .onlySwitch:
            return TVRowItem(id: ID.summary, title: SportsCopy.oneSwitch, subtitle: progress, symbol: "power")
        case .ready:
            if let error = status.lastError, !error.isEmpty, !status.isWorking {
                return TVRowItem(id: ID.summary, title: SportsCopy.phase(status), subtitle: error, symbol: "exclamationmark.triangle.fill")
            }
            let lastLooked = status.lastPass.map { SportsCopy.lastLooked(Date(timeIntervalSince1970: TimeInterval($0))) }
            let detail = [status.isWorking ? nil : SportsCopy.phase(status), lastLooked].compactMap { $0 }.joined(separator: " · ")
            return TVRowItem(id: ID.summary, title: SportsCopy.allReady, subtitle: detail, symbol: "checkmark.seal.fill")
        }
    }

    private func stepRow(_ step: SportsSetupStep, total: Int) -> TVRowItem {
        TVRowItem(
            id: ID.step + "\(step.number)",
            title: SportsCopy.groupTitle(step.group),
            subtitle: SportsCopy.stepOf(step.number, total),
            value: SportsCopy.state(step.state),
            symbol: step.state == .done ? "checkmark.circle.fill" : step.state == .failed ? "exclamationmark.circle.fill" : "\(step.number).circle"
        )
    }

    private func choiceRows(_ report: SportsReport) -> [TVRowItem] {
        var rows = [TVRowItem(id: ID.switchedOn, title: SportsCopy.researchNewFiles, value: report.settings.on ? String(localized: "On") : String(localized: "Off"), symbol: "power", isEnabled: !busy)]
        rows += report.libraries.map { library in
            TVRowItem(id: ID.library + library.key, title: library.title, value: library.chosen ? String(localized: "On") : String(localized: "Off"), symbol: "film.stack", isEnabled: !busy)
        }
        if report.settings.destination != nil {
            rows.append(TVRowItem(id: ID.agreement, title: report.settings.agreed ? SportsCopy.withdraw : SportsCopy.agree, symbol: report.settings.agreed ? "hand.raised.slash" : "hand.raised", isEnabled: !busy))
        }
        rows.append(TVRowItem(id: ID.checkAgain, title: SportsCopy.checkAgain, subtitle: busy ? CompanionCopy.checking : nil, symbol: "arrow.triangle.2.circlepath", isEnabled: !busy))
        rows.append(TVRowItem(id: ID.lookNow, title: SportsCopy.lookNow, symbol: "magnifyingglass", isEnabled: !busy))
        return rows
    }

    // MARK: Stage

    override func rowDidFocus(_ id: String?) {
        focusedID = id
        refreshStage()
    }

    /// Puts what the focused row is about on the stage; with nothing more specific, the newest result or the example.
    private func refreshStage() {
        guard let board else { return }
        let report = board.report
        let id = focusedID ?? ""
        if id == ID.live, failure == nil, let current = report.status.current, report.status.isWorking {
            stage.show(liveContent(current, report), key: ID.live)
        } else if id.hasPrefix(ID.step), let step = board.steps.first(where: { ID.step + "\($0.number)" == id }) {
            stage.show(stepContent(step, total: board.steps.count, owner: report.owner, settings: report.settings), key: id)
        } else if id.hasPrefix(ID.item), let item = report.items.first(where: { ID.item + $0.ratingKey == id }) {
            stage.show(itemContent(item), key: id)
        } else if id == ID.switchedOn {
            stage.show(TVSportsStageContent(heading: SportsCopy.researchNewFiles, body: SportsCopy.why(.on)), key: id)
        } else if id.hasPrefix(ID.library), let library = report.libraries.first(where: { ID.library + $0.key == id }) {
            stage.show(TVSportsStageContent(heading: library.title, body: SportsCopy.why(.libraries)), key: id)
        } else if id == ID.agreement, let destination = report.settings.destination {
            stage.show(TVSportsStageContent(heading: SportsCopy.title(.agreement), body: SportsCopy.agreeQuestion(destination)), key: id)
        } else if id == ID.unreachable, let failure {
            stage.show(TVSportsStageContent(eyebrow: SportsCopy.unreachableTitle, eyebrowTint: .systemOrange, body: failure), key: id)
        } else {
            stage.show(heroContent(board), key: "hero")
        }
    }

    private func heroContent(_ board: SportsBoard) -> TVSportsStageContent {
        var content: TVSportsStageContent
        if let hero = board.hero {
            content = TVSportsStageContent(eyebrow: SportsCopy.latest, art: .init(file: hero.fileName, title: SportsItemLabel.title(hero), words: hero.posterWords, posterPath: hero.posterPath), body: SportsCopy.meta(hero))
        } else {
            let words = SportsPosterWords(event: SportsCopy.exampleTitle, part: nil, headline: "")
            content = TVSportsStageContent(eyebrow: SportsCopy.example, art: .init(file: SportsCopy.exampleFile, title: SportsCopy.exampleTitle, words: words), body: SportsCopy.transformationLine)
        }
        switch mode {
        case .notPro?:
            content.body = [content.body, SportsCopy.forWhom].compactMap { $0 }.joined(separator: "\n\n")
        case .setup?, .onlySwitch?, .ready?:
            content.lines = board.steps.map { step in
                TVSportsStageContent.Line(symbol: step.state == .done ? "checkmark.circle.fill" : "\(step.number).circle", tint: step.state == .done ? Theme.Color.statusOK : Theme.Color.labelSecondary, title: "\(SportsCopy.stepOf(step.number, board.steps.count)) · \(SportsCopy.groupTitle(step.group))", detail: nil, emphasized: step.state != .done)
            }
        default:
            break
        }
        return content
    }

    private func liveContent(_ current: SportsStatus.Current, _ report: SportsReport) -> TVSportsStageContent {
        let model = report.model.map { SportsCopy.model($0.name) }
        let lines = current.newestSteps(6).enumerated().map { index, step in
            TVSportsStageContent.Line(symbol: SportsCopy.stepSymbol(step.kind), tint: index == 0 ? Theme.Color.accentText : Theme.Color.labelTertiary, title: SportsCopy.step(step), emphasized: index == 0)
        }
        return TVSportsStageContent(
            eyebrow: SportsCopy.phase(report.status),
            heading: current.name,
            body: [current.file, model].compactMap { $0 }.joined(separator: "\n"),
            lines: lines,
            runningSince: receivedAt.addingTimeInterval(-TimeInterval(current.elapsed))
        )
    }

    private func stepContent(_ step: SportsSetupStep, total: Int, owner: Bool, settings: SportsSettings) -> TVSportsStageContent {
        let lines = step.checks.map { check in
            let open = check.state != .done
            let detail = !open ? check.detail : check.settledInApp(owner: owner, settings: settings) ? SportsCopy.belowInChoices : [check.detail, check.fix].compactMap { $0 }.joined(separator: "\n")
            return TVSportsStageContent.Line(
                symbol: check.state == .done ? "checkmark.circle.fill" : check.state == .failed ? "exclamationmark.circle.fill" : "circle.dashed",
                tint: check.state == .done ? Theme.Color.statusOK : check.state == .failed ? .systemOrange : Theme.Color.labelSecondary,
                title: SportsCopy.title(check.requirement ?? .model),
                detail: detail,
                emphasized: open
            )
        }
        return TVSportsStageContent(
            eyebrow: "\(SportsCopy.stepOf(step.number, total)) · \(SportsCopy.state(step.state))",
            eyebrowTint: step.state == .done ? Theme.Color.statusOK : Theme.Color.accentText,
            heading: SportsCopy.groupTitle(step.group),
            body: SportsCopy.stepWhat(step.group),
            lines: lines
        )
    }

    private func itemContent(_ item: SportsItem) -> TVSportsStageContent {
        let matched = item.state == "matched" || item.state == "edited"
        let attention = item.state == "attention" || item.state == "failed"
        var body = [SportsCopy.meta(item)]
        if let summary = item.detail?.summary, !summary.isEmpty { body.append(summary) }
        let bouts = (item.detail?.lineup ?? []).prefix(3).map { bout in
            TVSportsStageContent.Line(symbol: "person.2", tint: Theme.Color.labelSecondary, title: bout.matchup, detail: bout.detail, emphasized: true)
        }
        return TVSportsStageContent(
            eyebrow: SportsCopy.itemState(item.state),
            eyebrowTint: attention ? .systemOrange : item.state == "matched" ? Theme.Color.statusOK : Theme.Color.labelSecondary,
            heading: matched ? nil : item.fileName,
            art: matched ? .init(file: item.fileName, title: SportsItemLabel.title(item), words: item.posterWords, posterPath: item.posterPath) : nil,
            body: body.filter { !$0.isEmpty }.joined(separator: "\n"),
            lines: Array(bouts)
        )
    }

    // MARK: Actions

    override func rowDidSelect(_ id: String) {
        if id == ID.unreachable { return startRefreshing() }
        if id == ID.summary, mode == .notPro {
            ProAccess.shared.requestUnlock(.sportsResearch) { [weak self] _ in self?.render() }
            return
        }
        guard !busy, let report = board?.report, report.owner, mode != .notPro, mode != .viewer else { return }
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
            presentConfirmation(title: SportsCopy.researchAgain, message: SportsCopy.redoQuestion, confirmTitle: SportsCopy.researchAgain) { [weak self] in
                self?.perform { source throws(CompanionError) in try await source.redoSports(ratingKey: key) }
            }
        case _ where id.hasPrefix(ID.step):
            let web = board?.steps.first { $0.group == .web && ID.step + "\($0.number)" == id }
            if web != nil, !report.settings.agreed { askToAgree() }
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
        guard !busy else { return }
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
                self?.presentAlert(title: SportsCopy.title, message: error.message)
            }
            self?.busy = false
            await self?.load()
            self?.resumeRefreshingIfShown()
        }
    }
}
