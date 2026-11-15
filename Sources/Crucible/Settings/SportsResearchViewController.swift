import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Settings › Crucible Server › Sports Research: what it does and for whom, every requirement with whether it is met
/// and how to meet it, the owner's choices, what the server is doing right now, and what it made of each file.
final class SportsResearchViewController: UICollectionViewController {
    private enum Section: Hashable {
        case intro
        case group(SportsRequirement.Group)
        case choices
        case now
        case results
    }

    private enum Row: Hashable {
        case summary
        case message(String)
        case check(String)
        case switchedOn
        case library(String)
        case noLibraries
        case agreement
        case checkAgain
        case lookNow
        case now
        case item(String)
        case nothingYet
    }

    private let source: any SportsSource
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var board: SportsBoard?
    private var failure: String?
    private var busy = false
    private var refreshTask: Task<Void, Never>?

    init(source: any SportsSource) {
        self.source = source
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SportsCopy.title
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "settings.sports"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = .supplementary
            config.footerMode = .supplementary
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRefreshing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Asks the server now and then again while the screen shows: every few seconds while it works, else every half minute.
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
            failure = nil
        } catch {
            failure = SportsCopy.failure(error, hasSports: await source.hasSports())
        }
        applySnapshot()
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            cell.contentConfiguration = configuration(for: row)
            cell.accessories = accessories(for: row)
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "settings.sports.\(identifier(row))"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.header(at: indexPath.section)
            content.textProperties.font = indexPath.section == 0 ? Theme.Font.subheadline : Theme.Font.footnote
            content.textProperties.color = Theme.Color.labelSecondary
            content.textProperties.transform = indexPath.section == 0 ? .none : .uppercase
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.footer(at: indexPath.section)
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func section(at index: Int) -> Section? {
        let sections = dataSource.snapshot().sectionIdentifiers
        return sections.indices.contains(index) ? sections[index] : nil
    }

    private func header(at index: Int) -> String? {
        guard let section = section(at: index) else { return nil }
        return switch section {
        case .intro: "\(SportsCopy.pitch)\n\n\(SportsCopy.forWhom)"
        case .group(let group): SportsCopy.groupTitle(group)
        case .choices: SportsCopy.settingsHeader
        case .now: SportsCopy.nowHeader
        case .results: board.map { "\(SportsCopy.resultsHeader) · \(SportsCopy.counts($0))" } ?? SportsCopy.resultsHeader
        }
    }

    private func footer(at index: Int) -> String? {
        guard let section = section(at: index) else { return nil }
        switch section {
        case .intro where board?.report.owner == false: return SportsCopy.ownerOnly
        case .intro where !ProAccess.shared.hasFullAccess: return SportsCopy.proPitch
        case .choices where board?.report.settings.agreed == true: return board?.report.settings.destination.map(SportsCopy.agreeQuestion)
        default: return nil
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.intro])
        guard let board else {
            snapshot.appendItems([failure.map(Row.message) ?? .summary], toSection: .intro)
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }
        snapshot.appendItems(failure.map { [.summary, .message($0)] } ?? [.summary], toSection: .intro)
        for (group, checks) in board.groups {
            snapshot.appendSections([.group(group)])
            snapshot.appendItems(checks.map { Row.check($0.id) }, toSection: .group(group))
        }
        if board.report.owner {
            snapshot.appendSections([.choices])
            var rows: [Row] = [.switchedOn]
            rows += board.report.libraries.isEmpty ? [.noLibraries] : board.report.libraries.map { Row.library($0.key) }
            if board.report.settings.destination != nil { rows.append(.agreement) }
            rows += [.checkAgain, .lookNow]
            snapshot.appendItems(rows, toSection: .choices)
        }
        snapshot.appendSections([.now])
        snapshot.appendItems([.now], toSection: .now)
        snapshot.appendSections([.results])
        let items = board.items
        snapshot.appendItems(items.isEmpty ? [.nothingYet] : items.map { Row.item($0.ratingKey) }, toSection: .results)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func identifier(_ row: Row) -> String {
        switch row {
        case .check(let id): "check.\(id)"
        case .library(let key): "library.\(key)"
        case .item(let key): "item.\(key)"
        default: String(describing: row).components(separatedBy: "(").first ?? "row"
        }
    }

    private func configuration(for row: Row) -> UIContentConfiguration {
        switch row {
        case .summary:
            guard let board else { return IconRowContentConfiguration(symbol: "sportscourt", title: SportsCopy.title, subtitle: CompanionCopy.checking) }
            let done = board.doneCount == board.total
            return IconRowContentConfiguration(
                symbol: done ? "checkmark.seal.fill" : "sportscourt",
                symbolColor: done ? Theme.Color.statusOK : nil,
                title: done ? SportsCopy.allReady : SportsCopy.progress(done: board.doneCount, of: board.total),
                subtitle: statusLine(board.report.status)
            )
        case .message(let text):
            return IconRowContentConfiguration(symbol: "exclamationmark.triangle", symbolColor: .systemOrange, title: SportsCopy.title, subtitle: text)
        case .check(let id):
            guard let check = check(id) else { return IconRowContentConfiguration(symbol: "circle", title: id) }
            let requirement = check.requirement ?? .model
            var lines = [SportsCopy.why(requirement)]
            if let report = board?.report, check.settledInApp(in: report) {
                lines.append(SportsCopy.belowInChoices)
            } else if check.state != .done {
                lines.append(check.detail)
                if let fix = check.fix { lines.append(fix) }
            }
            return IconRowContentConfiguration(symbol: symbol(check.state), symbolColor: color(check.state), title: SportsCopy.title(requirement), subtitle: lines.joined(separator: "\n"), value: check.state == .done ? nil : SportsCopy.state(check.state))
        case .switchedOn:
            let on = board?.report.settings.on ?? false
            return IconRowContentConfiguration(symbol: "power", title: SportsCopy.researchNewFiles, toggle: .init(isOn: on, isEnabled: !busy) { [weak self] wanted in self?.setOn(wanted) })
        case .library(let key):
            return IconRowContentConfiguration(symbol: "film.stack", title: library(key)?.title ?? key, isActionable: true)
        case .noLibraries:
            return IconRowContentConfiguration(symbol: "film.stack", symbolColor: .systemOrange, title: SportsCopy.title(.libraries), subtitle: SportsCopy.noLibraries)
        case .agreement:
            let agreed = board?.report.settings.agreed ?? false
            return IconRowContentConfiguration(symbol: agreed ? "hand.thumbsup.fill" : "hand.raised", symbolColor: agreed ? Theme.Color.statusOK : .systemOrange, title: agreed ? SportsCopy.withdraw : SportsCopy.agree, subtitle: agreed ? nil : board?.report.settings.destination.map(SportsCopy.agreeQuestion), isActionable: true)
        case .checkAgain:
            return IconRowContentConfiguration(symbol: "arrow.triangle.2.circlepath", title: SportsCopy.checkAgain, subtitle: busy ? CompanionCopy.checking : nil, isActionable: true)
        case .lookNow:
            return IconRowContentConfiguration(symbol: "magnifyingglass", title: SportsCopy.lookNow, isActionable: true)
        case .now:
            guard let status = board?.report.status else { return IconRowContentConfiguration(symbol: "clock", title: CompanionCopy.checking) }
            return IconRowContentConfiguration(symbol: status.isWorking ? "waveform" : "clock", symbolColor: status.isWorking ? Theme.Color.accent : nil, title: SportsCopy.phase(status), subtitle: nowDetail(status))
        case .item(let key):
            guard let item = item(key) else { return IconRowContentConfiguration(symbol: "circle", title: key) }
            let lines = [SportsCopy.itemState(item.state), item.note].filter { !$0.isEmpty }
            return IconRowContentConfiguration(symbol: SportsCopy.itemSymbol(item.state), symbolColor: itemColor(item.state), title: SportsItemLabel.title(item), subtitle: lines.joined(separator: "\n"))
        case .nothingYet:
            return IconRowContentConfiguration(symbol: "tray", title: SportsCopy.nothingYet)
        }
    }

    private func accessories(for row: Row) -> [UICellAccessory] {
        switch row {
        case .library(let key): library(key)?.chosen == true ? [.checkmark(options: .init(tintColor: Theme.Color.accent))] : []
        default: []
        }
    }

    private func itemColor(_ state: String) -> UIColor {
        switch state {
        case "matched": Theme.Color.statusOK
        case "edited": Theme.Color.labelSecondary
        default: .systemOrange
        }
    }

    private func check(_ id: String) -> SportsCheck? { board?.report.checks.first { $0.id == id } }
    private func library(_ key: String) -> SportsLibrary? { board?.report.libraries.first { $0.key == key } }
    private func item(_ key: String) -> SportsItem? { board?.report.items.first { $0.ratingKey == key } }

    private func symbol(_ state: SportsCheck.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .missing: "circle.dashed"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func color(_ state: SportsCheck.State) -> UIColor {
        switch state {
        case .done: Theme.Color.statusOK
        case .missing: Theme.Color.labelTertiary
        case .failed: .systemOrange
        }
    }

    private func statusLine(_ status: SportsStatus) -> String {
        [SportsCopy.phase(status), status.current?.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func nowDetail(_ status: SportsStatus) -> String? {
        var lines: [String] = []
        if let current = status.current, status.isWorking { lines.append("\(current.name)\n\(current.step)") }
        if status.queued > 0 { lines.append(SportsCopy.queued(status.queued)) }
        if let last = status.lastPass { lines.append(SportsCopy.lastLooked(Date(timeIntervalSince1970: TimeInterval(last)))) }
        if let error = status.lastError, !error.isEmpty { lines.append(error) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .library, .agreement, .checkAgain, .lookNow: true
        case .check(let id): check(id).map { $0.state != .done && $0.fix != nil } ?? false
        default: false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .library(let key): if let library = library(key) { toggle(library) }
        case .agreement: board?.report.settings.agreed == true ? change(agree: false) : askToAgree()
        case .checkAgain: recheck()
        case .lookNow: lookNow()
        case .check(let id):
            guard let check = check(id) else { return }
            if check.requirement == .agreement, board?.report.owner == true { askToAgree() } else { offerCopy(check) }
        default: break
        }
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard board?.report.owner == true, let indexPath = indexPaths.first, case .item(let key) = dataSource.itemIdentifier(for: indexPath), let item = item(key) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(title: SportsCopy.researchAgain, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.redo(item) }])
        })
    }

    /// Turning research on is part of Crucible Pro; turning it off never is.
    private func setOn(_ wanted: Bool) {
        guard wanted else { return change(on: false) }
        ProAccess.shared.requestUnlock(.sportsResearch) { [weak self] unlocked in
            if unlocked { self?.change(on: true) } else { self?.applySnapshot() }
        }
    }

    private func toggle(_ library: SportsLibrary) {
        guard let board else { return }
        var chosen = board.report.libraries.filter(\.chosen).map(\.key)
        if library.chosen { chosen.removeAll { $0 == library.key } } else { chosen.append(library.key) }
        change(libraries: chosen)
    }

    private func askToAgree() {
        guard let destination = board?.report.settings.destination else { return }
        let alert = UIAlertController(title: SportsCopy.title(.agreement), message: SportsCopy.agreeQuestion(destination), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SportsCopy.agree, style: .default) { [weak self] _ in self?.change(agree: true) })
        present(alert, animated: true)
    }

    private func offerCopy(_ check: SportsCheck) {
        guard let fix = check.fix else { return }
        let command = sportsCommand(in: fix)
        let message = command.map { "\(check.detail)\n\n\(SportsCopy.onTheServer)\n\($0)" } ?? "\(check.detail)\n\n\(fix)"
        let sheet = UIAlertController(title: SportsCopy.title(check.requirement ?? .model), message: message, preferredStyle: .actionSheet)
        if let command {
            sheet.addAction(UIAlertAction(title: SportsCopy.copyCommand, style: .default) { _ in
                UIPasteboard.general.string = command
                Haptics.success()
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let cell = collectionView.indexPathsForSelectedItems?.first.flatMap(collectionView.cellForItem(at:)) {
            sheet.popoverPresentationController?.sourceView = cell
        } else {
            sheet.popoverPresentationController?.sourceView = collectionView
        }
        present(sheet, animated: true)
    }

    private func change(on: Bool? = nil, libraries: [String]? = nil, agree: Bool? = nil) {
        if let board { self.board = SportsBoard(report: board.report.expecting(on: on, libraries: libraries, agree: agree)) }
        perform { source throws(CompanionError) in try await source.changeSports(on: on, libraries: libraries, agree: agree) }
    }

    private func recheck() {
        perform { source throws(CompanionError) in try await source.recheckSports() }
    }

    private func lookNow() {
        perform { source throws(CompanionError) in try await source.runSports() }
    }

    private func redo(_ item: SportsItem) {
        perform { source throws(CompanionError) in try await source.redoSports(ratingKey: item.ratingKey) }
    }

    /// Runs one owner action, shows it as busy meanwhile, and asks the server again afterwards.
    private func perform(_ action: @escaping @Sendable (any SportsSource) async throws(CompanionError) -> Void) {
        guard !busy else { return }
        busy = true
        applySnapshot()
        Task { [weak self, source] in
            do throws(CompanionError) {
                try await action(source)
                Haptics.success()
            } catch {
                Haptics.error()
                self?.failure = error.message
                if let self { CompanionPairingFlow.show(error.message, from: self) }
            }
            self?.busy = false
            await self?.load()
            self?.resumeRefreshingIfShown()
        }
    }
}
