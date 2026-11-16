import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// Sports Research on Linux (`TVSportsResearchViewController`), opened from the paired Crucible Server and free here (D1).
/// The rows are what someone can do or look at: where setup stands, the research running now, the four setup steps, the
/// owner's choices and every researched file. The stage beside them shows whatever has the focus: the newest result or an
/// example, the live research ticking, a step's checks, or a file's poster, card and new title.
@MainActor
final class SportsResearchScreen: SettingsScaffold {
    private enum ID {
        static let unreachable = "sports.unreachable"
        static let summary = "sports.summary"
        static let live = "sports.live"
        static let step = "sports.step."
        static let need = "sports.need."
        static let switchedOn = "sports.on"
        static let agreement = "sports.agreement"
        static let checkAgain = "sports.checkAgain"
        static let lookNow = "sports.lookNow"
        static let results = "sports.results"
        static let nothingYet = "sports.nothingYet"
        static let library = "sports.library."
        static let takeBack = "sports.takeBack."
        static let item = "sports.item."
    }

    private let source: any SportsSource
    private let stage = SportsStageView()
    private var board: SportsBoard?
    private var receivedAt = Date()
    private var failure: String?
    private var busy = false
    private var refreshTask: Task<Void, Never>?
    private var focusedID: String?

    /// What needs a look, in the Apple TV's system orange.
    private static let attention = Color(hex: 0xFF9F0A)

    /// Linux has no Pro: research is the owner's to set up, or a viewer's to watch.
    private var mode: SportsMode? { board?.mode(isPro: true) }

    init(source: any SportsSource) {
        self.source = source
        super.init(title: SportsCopy.title)
        pinsContext = true
        installContext(stage)
        presentState(.loading(title: SportsCopy.title))
    }

    override func screenDidAppear() {
        startRefreshing()
    }

    override func screenWillDisappear() {
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
                if !self.busy { await self.load() }
                let working = self.board?.report.status.isWorking == true || (self.board?.report.status.queued ?? 0) > 0
                let wait: Double = self.failure != nil ? 15 : working ? 3 : 30
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
            presentState(.error(title: SportsCopy.title, message: message, retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.startRefreshing() }))
        }
    }

    // MARK: Rows

    private func render() {
        guard let board, let mode else { return }
        let report = board.report
        var rows: [RowItem] = []
        if let failure {
            rows.append(RowItem(id: ID.unreachable, title: SportsCopy.unreachableTitle, subtitle: failure == SportsCopy.updateServer ? failure : SportsCopy.unreachableBody,
                                symbol: "wifi.exclamationmark"))
        }
        rows.append(summaryRow(board, mode))
        if failure == nil, report.status.isWorking, let current = report.status.current {
            rows.append(RowItem(id: ID.live, title: SportsCopy.phase(report.status), subtitle: current.name,
                                value: report.status.queued > 0 ? SportsCopy.queued(report.status.queued) : nil, symbol: "waveform"))
        }
        switch mode {
        case .notPro, .viewer:
            break
        case .setup, .onlySwitch:
            rows += board.steps.map { stepRow($0, total: board.steps.count) }
            rows += needRows()
            rows += choiceRows(report)
        case .ready:
            rows += choiceRows(report)
        }
        let items = board.items
        if !items.isEmpty {
            rows.append(RowItem(id: ID.results, title: SportsCopy.resultsHeader, value: SportsCopy.counts(board), symbol: "square.grid.2x2", isStatic: true))
            rows += items.map { item in
                RowItem(id: ID.item + item.ratingKey, title: SportsItemLabel.title(item), subtitle: SportsCopy.meta(item),
                        value: item.state == "matched" ? nil : SportsCopy.itemState(item.state), symbol: Symbol(SportsCopy.itemSymbol(item.state)))
            }
        } else if mode == .ready {
            rows.append(RowItem(id: ID.nothingYet, title: SportsCopy.nothingYet, symbol: "tray", isStatic: true))
        }
        setRows(rows)
        refreshStage()
    }

    private func summaryRow(_ board: SportsBoard, _ mode: SportsMode) -> RowItem {
        let status = board.report.status
        let progress = SportsCopy.progress(done: board.doneCount, of: board.total)
        switch mode {
        case .notPro, .viewer:
            return RowItem(id: ID.summary, title: SportsCopy.phase(status), subtitle: SportsCopy.ownerOnly, symbol: "eye")
        case .setup:
            return RowItem(id: ID.summary, title: SportsCopy.setUpInFour, subtitle: progress, symbol: "list.number")
        case .onlySwitch:
            return RowItem(id: ID.summary, title: SportsCopy.oneSwitch, subtitle: progress, symbol: "power")
        case .ready:
            if status.undoing > 0 {
                return RowItem(id: ID.summary, title: SportsCopy.undoing(status.undoing), symbol: "arrow.uturn.backward.circle")
            }
            if status.isPausedForSearch {
                return RowItem(id: ID.summary, title: SportsCopy.phase(status), subtitle: SportsCopy.searchPaused(status), symbol: "pause.circle.fill")
            }
            if let error = status.lastError, !error.isEmpty, !status.isWorking {
                return RowItem(id: ID.summary, title: SportsCopy.phase(status), subtitle: error, symbol: "exclamationmark.triangle.fill")
            }
            let lastLooked = status.lastPass.map { SportsCopy.lastLooked(Date(timeIntervalSince1970: TimeInterval($0))) }
            let detail = [status.isWorking ? nil : SportsCopy.phase(status), lastLooked].compactMap { $0 }.joined(separator: " · ")
            return RowItem(id: ID.summary, title: SportsCopy.allReady, subtitle: detail, symbol: "checkmark.seal.fill")
        }
    }

    /// The computer, graphics memory and model research needs, under a heading row.
    private func needRows() -> [RowItem] {
        [RowItem(id: ID.need + "header", title: SportsCopy.whatYouNeed, symbol: "checklist", isStatic: true)]
            + SportsCopy.needs.enumerated().map { index, need in
                RowItem(id: ID.need + "\(index)", title: need.title, subtitle: need.detail, symbol: Symbol(need.symbol), isStatic: true)
            }
    }

    private func stepRow(_ step: SportsSetupStep, total: Int) -> RowItem {
        let symbol = step.state == .done ? "checkmark.circle.fill" : step.state == .failed ? "exclamationmark.circle.fill" : "circle.dashed"
        return RowItem(id: ID.step + "\(step.number)", title: SportsCopy.groupTitle(step.group), subtitle: SportsCopy.stepOf(step.number, total),
                       value: SportsCopy.state(step.state), symbol: Symbol(symbol))
    }

    private func choiceRows(_ report: SportsReport) -> [RowItem] {
        var rows = [RowItem.onOff(id: ID.switchedOn, title: SportsCopy.researchNewFiles, isOn: report.settings.on, symbol: "power", isEnabled: !busy)]
        rows += report.libraries.map { library in
            RowItem(id: ID.library + library.key, title: library.title, value: library.chosen ? SportsCopy.kind(library.kind) : String(localized: "Off"),
                    symbol: "film.stack", isEnabled: !busy)
        }
        rows += report.libraries.filter { !$0.chosen && $0.researched > 0 }.map { library in
            RowItem(id: ID.takeBack + library.key, title: SportsCopy.takeBackLibrary(library.title, files: library.researched), symbol: "arrow.uturn.backward",
                    isDestructive: true, isEnabled: !busy)
        }
        if report.settings.destination != nil {
            rows.append(RowItem(id: ID.agreement, title: report.settings.agreed ? SportsCopy.withdraw : SportsCopy.agree,
                                symbol: report.settings.agreed ? "hand.raised.slash" : "hand.raised", isEnabled: !busy))
        }
        rows.append(RowItem(id: ID.checkAgain, title: SportsCopy.checkAgain, subtitle: busy ? CompanionCopy.checking : nil, symbol: "arrow.triangle.2.circlepath",
                            isEnabled: !busy))
        rows.append(RowItem(id: ID.lookNow, title: SportsCopy.lookNow, symbol: "magnifyingglass", isEnabled: !busy))
        return rows
    }

    // MARK: Stage

    override func rowFocused(_ id: String) {
        focusedID = id
        refreshStage()
    }

    /// Puts what the focused row is about on the stage; with nothing more specific, the newest result or the example.
    private func refreshStage() {
        guard let board else { return }
        let report = board.report
        let id = focusedID ?? ""
        let palette = Theme.current.palette
        if id == ID.live, failure == nil, let current = report.status.current, report.status.isWorking {
            stage.show(liveContent(current, report), key: ID.live)
        } else if id.hasPrefix(ID.step), let step = board.steps.first(where: { ID.step + "\($0.number)" == id }) {
            stage.show(stepContent(step, total: board.steps.count, owner: report.owner, settings: report.settings), key: id)
        } else if id.hasPrefix(ID.item), let item = report.items.first(where: { ID.item + $0.ratingKey == id }) {
            stage.show(itemContent(item), key: id)
        } else if id == ID.switchedOn {
            stage.show(SportsStageContent(heading: SportsCopy.researchNewFiles, body: SportsCopy.why(.on)), key: id)
        } else if id.hasPrefix(ID.library), let library = report.libraries.first(where: { ID.library + $0.key == id }) {
            stage.show(SportsStageContent(heading: library.title, body: SportsCopy.why(.libraries)), key: id)
        } else if id == ID.agreement, let destination = report.settings.destination {
            stage.show(SportsStageContent(heading: SportsCopy.title(.agreement), body: SportsCopy.agreeQuestion(destination)), key: id)
        } else if id == ID.unreachable, let failure {
            stage.show(SportsStageContent(eyebrow: SportsCopy.unreachableTitle, eyebrowTint: Self.attention, body: failure), key: id)
        } else {
            stage.show(heroContent(board), key: "hero")
        }
    }

    private func heroContent(_ board: SportsBoard) -> SportsStageContent {
        let palette = Theme.current.palette
        var content: SportsStageContent
        if let hero = board.hero {
            content = SportsStageContent(eyebrow: SportsCopy.latest, art: .init(file: hero.fileName, title: SportsItemLabel.title(hero), words: hero.posterWords,
                                                                                posterPath: hero.posterPath, kind: hero.kind), body: SportsCopy.meta(hero))
        } else {
            let words = SportsPosterWords(event: SportsCopy.exampleTitle, part: nil, headline: "")
            content = SportsStageContent(eyebrow: SportsCopy.example, art: .init(file: SportsCopy.exampleFile, title: SportsCopy.exampleTitle, words: words),
                                         body: SportsCopy.transformationLine)
        }
        if mode == .setup || mode == .onlySwitch || mode == .ready {
            content.lines = board.steps.map { step in
                SportsStageContent.Line(symbol: Symbol(step.state == .done ? "checkmark.circle.fill" : "circle.dashed"),
                                        tint: step.state == .done ? palette.statusOK : palette.labelSecondary,
                                        title: "\(SportsCopy.stepOf(step.number, board.steps.count)) · \(SportsCopy.groupTitle(step.group))",
                                        emphasized: step.state != .done)
            }
        }
        return content
    }

    private func liveContent(_ current: SportsStatus.Current, _ report: SportsReport) -> SportsStageContent {
        let palette = Theme.current.palette
        let model = report.model.map { SportsCopy.model($0.name) }
        let lines = current.newestSteps(6).enumerated().map { index, step in
            SportsStageContent.Line(symbol: Symbol(SportsCopy.stepSymbol(step.kind)), tint: index == 0 ? palette.accentText : palette.labelTertiary,
                                    title: SportsCopy.step(step), emphasized: index == 0)
        }
        return SportsStageContent(eyebrow: SportsCopy.phase(report.status), heading: current.name, body: [current.file, model].compactMap { $0 }.joined(separator: "\n"),
                                  lines: lines, runningSince: receivedAt.addingTimeInterval(-TimeInterval(current.elapsed)))
    }

    private func stepContent(_ step: SportsSetupStep, total: Int, owner: Bool, settings: SportsSettings) -> SportsStageContent {
        let palette = Theme.current.palette
        let lines = step.checks.map { check in
            let open = check.state != .done
            let detail = !open ? check.detail : check.settledInApp(owner: owner, settings: settings) ? SportsCopy.belowInChoices
                : [check.detail, check.fix].compactMap { $0 }.joined(separator: "\n")
            return SportsStageContent.Line(
                symbol: Symbol(check.state == .done ? "checkmark.circle.fill" : check.state == .failed ? "exclamationmark.circle.fill" : "circle.dashed"),
                tint: check.state == .done ? palette.statusOK : check.state == .failed ? Self.attention : palette.labelSecondary,
                title: SportsCopy.title(check.requirement ?? .model), detail: detail, emphasized: open
            )
        }
        return SportsStageContent(eyebrow: "\(SportsCopy.stepOf(step.number, total)) · \(SportsCopy.state(step.state))",
                                  eyebrowTint: step.state == .done ? palette.statusOK : palette.accentText, heading: SportsCopy.groupTitle(step.group),
                                  body: SportsCopy.stepWhat(step.group), lines: lines)
    }

    private func itemContent(_ item: SportsItem) -> SportsStageContent {
        let palette = Theme.current.palette
        let matched = item.state == "matched" || item.state == "edited"
        let attention = item.state == "attention" || item.state == "failed"
        var body = [SportsCopy.meta(item)]
        if let detail = item.detail, detail.kind != .sports {
            body.append([detail.series, detail.studio].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if let summary = item.detail?.summary, !summary.isEmpty { body.append(summary) }
        let bouts = (item.detail?.lineup ?? []).prefix(3).map { bout in
            SportsStageContent.Line(symbol: "person.2", tint: palette.labelSecondary, title: bout.matchup, detail: bout.detail, emphasized: true)
        }
        let cast = (item.detail?.people ?? []).prefix(4).map { person in
            SportsStageContent.Line(symbol: "person", tint: palette.labelSecondary, title: person, emphasized: true)
        }
        return SportsStageContent(
            eyebrow: SportsCopy.itemState(item.state),
            eyebrowTint: attention ? Self.attention : item.state == "matched" ? palette.statusOK : palette.labelSecondary,
            heading: matched ? nil : item.fileName,
            art: matched ? .init(file: item.fileName, title: SportsItemLabel.title(item), words: item.posterWords, posterPath: item.showsArtwork ? item.posterPath : nil,
                                 kind: item.kind) : nil,
            body: body.filter { !$0.isEmpty }.joined(separator: "\n"),
            lines: bouts.isEmpty ? Array(cast) : Array(bouts)
        )
    }

    // MARK: Actions

    override func rowSelected(_ id: String) {
        if id == ID.unreachable { return startRefreshing() }
        guard let window, !busy, let report = board?.report, report.owner, mode != .viewer, mode != .notPro else { return }
        switch id {
        case ID.switchedOn:
            change(on: !report.settings.on)
        case ID.agreement:
            report.settings.agreed ? change(agree: false) : askToAgree()
        case ID.checkAgain:
            perform { source throws(CompanionError) in try await source.recheckSports() }
        case ID.lookNow:
            perform { source throws(CompanionError) in try await source.runSports() }
        case _ where id.hasPrefix(ID.library):
            if let library = report.libraries.first(where: { ID.library + $0.key == id }) { toggle(library, in: report) }
        case _ where id.hasPrefix(ID.takeBack):
            guard let library = report.libraries.first(where: { ID.takeBack + $0.key == id }) else { return }
            AlertView.confirm(title: SportsCopy.takeBackLibrary(library.title, files: library.researched), message: SportsCopy.takeBackLibraryQuestion(library.researched),
                              confirm: SportsCopy.takeBack, in: window) { [weak self] in
                self?.perform { source throws(CompanionError) in try await source.undoSports(library: library.key) }
            }
        case _ where id.hasPrefix(ID.item):
            offerItemActions(ratingKey: String(id.dropFirst(ID.item.count)), in: report)
        case _ where id.hasPrefix(ID.step):
            let web = board?.steps.first { $0.group == .web && ID.step + "\($0.number)" == id }
            if web != nil, !report.settings.agreed { askToAgree() }
        default:
            break
        }
    }

    /// A researched file: Research Again, and Take Back where the server can undo what it wrote.
    private func offerItemActions(ratingKey key: String, in report: SportsReport) {
        guard let window else { return }
        guard report.items.first(where: { $0.ratingKey == key })?.canTakeBack == true else {
            AlertView(title: SportsCopy.researchAgain, message: SportsCopy.redoQuestion, actions: [
                AlertView.Action(SportsCopy.researchAgain) { [weak self] in self?.perform { source throws(CompanionError) in try await source.redoSports(ratingKey: key) } },
                AlertView.Action(String(localized: "Cancel"), role: .cancel),
            ]).present(in: window)
            return
        }
        AlertView(title: report.items.first { $0.ratingKey == key }.map(SportsItemLabel.title) ?? SportsCopy.title, actions: [
            AlertView.Action(SportsCopy.researchAgain) { [weak self] in self?.perform { source throws(CompanionError) in try await source.redoSports(ratingKey: key) } },
            AlertView.Action(SportsCopy.takeBack, role: .destructive) { [weak self] in
                self?.perform { source throws(CompanionError) in try await source.undoSports(ratingKey: key) }
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ]).present(in: window)
    }

    private func askToAgree() {
        guard let window, let destination = board?.report.settings.destination else { return }
        AlertView(title: SportsCopy.title(.agreement), message: SportsCopy.agreeQuestion(destination), actions: [
            AlertView.Action(SportsCopy.agree) { [weak self] in self?.change(agree: true) },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ]).present(in: window)
    }

    /// Choosing a library asks what it holds; taking one out of research asks whether what it wrote stays.
    private func toggle(_ library: SportsLibrary, in report: SportsReport) {
        guard let window else { return }
        let chosen = report.libraries.filter(\.chosen).map(\.key)
        guard library.chosen else {
            guard library.holdsKinds else { return change(libraries: chosen + [library.key]) }
            AlertView(title: SportsCopy.kindQuestion(library.title), message: SportsCopy.kindExplanation, actions: SportsKind.allCases.map { kind in
                AlertView.Action(SportsCopy.kind(kind)) { [weak self] in self?.change(libraries: chosen + [library.key], kinds: [library.key: kind]) }
            } + [AlertView.Action(String(localized: "Cancel"), role: .cancel)]).present(in: window)
            return
        }
        let rest = chosen.filter { $0 != library.key }
        guard library.researched > 0 else { return change(libraries: rest) }
        AlertView(title: SportsCopy.stopQuestion(library.title), message: SportsCopy.stopExplanation, actions: [
            AlertView.Action(SportsCopy.stopAndKeep) { [weak self] in self?.change(libraries: rest) },
            AlertView.Action(SportsCopy.stopAndTakeBack, role: .destructive) { [weak self] in
                guard let self, !self.busy else { return }
                self.board = SportsBoard(report: report.expecting(libraries: rest))
                self.perform { source throws(CompanionError) in
                    try await source.changeSports(on: nil, libraries: rest, kinds: [:], agree: nil)
                    try await source.undoSports(library: library.key)
                }
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ]).present(in: window)
    }

    private func change(on: Bool? = nil, libraries: [String]? = nil, kinds: [String: SportsKind] = [:], agree: Bool? = nil) {
        guard !busy else { return }
        if let board { self.board = SportsBoard(report: board.report.expecting(on: on, libraries: libraries, kinds: kinds, agree: agree)) }
        perform { source throws(CompanionError) in try await source.changeSports(on: on, libraries: libraries, kinds: kinds, agree: agree) }
    }

    private func perform(_ action: @escaping @Sendable (any SportsSource) async throws(CompanionError) -> Void) {
        guard !busy else { return }
        busy = true
        render()
        Task { [weak self, source] in
            do throws(CompanionError) {
                try await action(source)
            } catch {
                if let window = self?.window { AlertView.notice(title: SportsCopy.title, message: error.message, in: window) }
            }
            self?.busy = false
            await self?.load()
            if self?.window != nil { self?.startRefreshing() }
        }
    }
}
