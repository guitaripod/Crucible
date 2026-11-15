import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Settings › Crucible Server › Sports Research: the newest file becoming its title (or an example of it), one pill
/// that says where things stand, the research at work, setup in four steps for the owner, the results as a poster
/// grid with a detail sheet each, and the owner's choices once everything is ready.
final class SportsResearchViewController: UICollectionViewController {
    private enum Section: Hashable {
        case banner, hero, pill, live, how, setup, results, choices
    }

    private enum Choice: Hashable {
        case on, library(String), agreement, checkAgain, lookNow
    }

    private enum Row: Hashable {
        case banner, hero, pill, live
        case step(SportsRequirement.Group)
        case result(String)
        case empty
        case choice(Choice)
        case how(Int)
    }

    private enum Filter: Int {
        case all, needsALook
    }

    /// Which setup step is open: the first one left to do, one the owner opened, or none.
    private enum Expansion: Equatable {
        case automatic
        case group(SportsRequirement.Group)
        case none
    }

    private let source: any SportsSource
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var board: SportsBoard?
    private var receivedAt = Date()
    private var failure: String?
    private var busy = false
    private var refreshTask: Task<Void, Never>?
    private var setupShown: Bool?
    private var expansion = Expansion.automatic
    private var filter = Filter.all

    init(source: any SportsSource) {
        self.source = source
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isPro: Bool { ProAccess.shared.hasFullAccess }
    private var openGroup: SportsRequirement.Group? {
        switch expansion {
        case .automatic: board?.firstOpenStep?.group
        case .group(let group): group
        case .none: nil
        }
    }
    private var mode: SportsMode? { board?.mode(isPro: isPro) }
    private var showsSetup: Bool {
        guard let mode else { return false }
        switch mode {
        case .setup, .onlySwitch: return setupShown ?? true
        case .ready: return setupShown ?? false
        case .notPro, .viewer: return false
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SportsCopy.title
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "settings.sports"
        collectionView.collectionViewLayout = makeLayout()
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

    /// Asks the server now and then again while the screen shows: every few seconds while it works, else every half minute,
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
            advance(from: board, to: SportsBoard(report: report))
            board = SportsBoard(report: report)
            receivedAt = Date()
            failure = nil
        } catch {
            guard !Task.isCancelled, !busy else { return }
            failure = SportsCopy.failure(error, hasSports: await source.hasSports())
        }
        applySnapshot()
    }

    /// Starts the polling again after an action, unless the screen was left while the action ran.
    private func resumeRefreshingIfShown() {
        guard viewIfLoaded?.window != nil else { return }
        startRefreshing()
    }

    /// A step that just turned done says so with a tap of the haptics, and the next open step opens unless the owner chose one.
    private func advance(from old: SportsBoard?, to new: SportsBoard) {
        guard let old else { return }
        let before = Set(old.steps.filter { $0.state == .done }.map(\.group))
        let after = Set(new.steps.filter { $0.state == .done }.map(\.group))
        let finished = after.subtracting(before)
        guard !finished.isEmpty else { return }
        Haptics.success()
        if case .group(let group) = expansion, finished.contains(group) { expansion = .automatic }
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = dataSource?.sectionIdentifier(for: index) else { return nil }
            switch section {
            case .results: return resultsSection(environment)
            case .choices: return choicesSection(environment)
            case .how: return howSection(environment)
            default: return cardSection(environment, spacing: section == .setup ? Theme.Space.s : 0)
            }
        }
    }

    private func cardSection(_ environment: NSCollectionLayoutEnvironment, spacing: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.xs, leading: Theme.Space.m, bottom: Theme.Space.xs, trailing: Theme.Space.m)
        Theme.centerReadable(section, environment)
        return section
    }

    private func resultsSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let large = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let columns = large ? 1 : max(2, Int((width - 2 * Theme.Space.m) / 170))
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .estimated(320)))
        item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.xs, bottom: 0, trailing: Theme.Space.xs)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(320)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Theme.Space.m
        section.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.s, leading: Theme.Space.s, bottom: Theme.Space.l, trailing: Theme.Space.s)
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80)), elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        header.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.xs, bottom: 0, trailing: Theme.Space.xs)
        section.boundarySupplementaryItems = [header]
        return section
    }

    private func howSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration.wellRows()
        config.headerMode = .supplementary
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        Theme.centerReadable(section, environment)
        return section
    }

    private func choicesSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration.wellRows()
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        Theme.centerReadable(section, environment)
        return section
    }

    // MARK: Data source

    private func configureDataSource() {
        let card = UICollectionView.CellRegistration<UICollectionViewCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            cell.contentConfiguration = cardConfiguration(row)
            cell.accessibilityIdentifier = "settings.sports.\(identifier(row))"
        }
        let result = UICollectionView.CellRegistration<UICollectionViewCell, Row> { [weak self] cell, _, row in
            guard let self, case .result(let key) = row, let item = board?.report.items.first(where: { $0.ratingKey == key }) else { return }
            cell.contentConfiguration = SportsResultConfiguration(item: item)
            cell.accessibilityIdentifier = "settings.sports.item.\(key)"
        }
        let list = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            cell.contentConfiguration = listConfiguration(row)
            cell.accessories = accessories(row)
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "settings.sports.\(identifier(row))"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            switch row {
            case .result: collectionView.dequeueConfiguredReusableCell(using: result, for: indexPath, item: row)
            case .choice, .empty, .how: collectionView.dequeueConfiguredReusableCell(using: list, for: indexPath, item: row)
            default: collectionView.dequeueConfiguredReusableCell(using: card, for: indexPath, item: row)
            }
        }
        let resultsHeader = UICollectionView.SupplementaryRegistration<SportsResultsHeader>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, _ in
            self?.configure(view)
        }
        let listHeader = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .how ? SportsCopy.howItWorks : SportsCopy.settingsHeader
            content.textProperties.font = Theme.Font.footnote
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        let listFooter = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, _ in
            cell.contentConfiguration = self?.choicesFooter()
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
            if section == .results {
                return collectionView.dequeueConfiguredReusableSupplementary(using: resultsHeader, for: indexPath)
            }
            return kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: listHeader, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: listFooter, for: indexPath)
        }
    }

    private func configure(_ header: SportsResultsHeader) {
        guard let board else { return }
        header.configure(title: SportsCopy.resultsHeader, counts: SportsCopy.counts(board), needing: board.needingALookCount, filter: filter.rawValue) { [weak self] value in
            self?.filter = Filter(rawValue: value) ?? .all
            self?.applySnapshot(animated: true)
        }
    }

    /// Under the owner's choices, once they agreed: where searches go.
    private func choicesFooter() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.groupedFooter()
        content.text = board?.report.settings.agreed == true ? board?.report.settings.destination.map(SportsCopy.agreeQuestion) : nil
        content.textProperties.font = Theme.Font.caption1Regular
        content.textProperties.color = Theme.Color.labelSecondary
        return content
    }

    /// Headers and footers on screen are not reconfigured with the items, so they take the new counts and agreement here.
    private func refreshSupplementaries() {
        for case let header as SportsResultsHeader in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
            configure(header)
        }
        for case let footer as UICollectionViewListCell in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter) {
            footer.contentConfiguration = choicesFooter()
        }
    }

    private func applySnapshot(animated: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        defer {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: animated && !UIAccessibility.isReduceMotionEnabled)
            refreshSupplementaries()
            showUnavailable()
        }
        guard let board, let mode else { return }
        if failure != nil {
            snapshot.appendSections([.banner])
            snapshot.appendItems([.banner], toSection: .banner)
        }
        snapshot.appendSections([.hero, .pill])
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems([.pill], toSection: .pill)
        if failure == nil, board.report.status.isWorking, board.report.status.current != nil {
            snapshot.appendSections([.live])
            snapshot.appendItems([.live], toSection: .live)
        }
        if mode == .notPro || mode == .viewer {
            snapshot.appendSections([.how])
            snapshot.appendItems(SportsCopy.howSteps.indices.map(Row.how), toSection: .how)
        }
        if showsSetup {
            snapshot.appendSections([.setup])
            snapshot.appendItems(board.steps.map { Row.step($0.group) }, toSection: .setup)
        }
        if !board.report.items.isEmpty || mode == .ready {
            snapshot.appendSections([.results])
            let shown = filter == .needsALook ? board.needingALook : board.items
            snapshot.appendItems(shown.isEmpty ? [.empty] : shown.map { Row.result($0.ratingKey) }, toSection: .results)
        }
        if mode == .ready {
            snapshot.appendSections([.choices])
            var rows: [Row] = [.choice(.on)]
            rows += board.report.libraries.map { Row.choice(.library($0.key)) }
            if board.report.settings.destination != nil { rows.append(.choice(.agreement)) }
            rows += [.choice(.checkAgain), .choice(.lookNow)]
            snapshot.appendItems(rows, toSection: .choices)
        }
    }

    /// With nothing loaded yet: checking, or why the server cannot be shown, with Try Again.
    private func showUnavailable() {
        guard board == nil else {
            contentUnavailableConfiguration = nil
            return
        }
        guard let failure else {
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = SportsCopy.title
            contentUnavailableConfiguration = loading
            return
        }
        var unavailable = UIContentUnavailableConfiguration.empty()
        unavailable.image = UIImage(systemName: "sportscourt")
        unavailable.text = SportsCopy.title
        unavailable.secondaryText = failure
        var retry = UIButton.Configuration.filled()
        retry.title = String(localized: "Try Again")
        unavailable.button = retry
        unavailable.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.startRefreshing() }
        contentUnavailableConfiguration = unavailable
    }

    private func identifier(_ row: Row) -> String {
        switch row {
        case .step(let group): "step.\(group.rawValue + 1)"
        case .choice(.library(let key)): "library.\(key)"
        case .choice(let choice): "\(choice)"
        case .how(let index): "how.\(index)"
        default: "\(row)"
        }
    }
}

// MARK: Cards

extension SportsResearchViewController {
    private func cardConfiguration(_ row: Row) -> UIContentConfiguration? {
        guard let board, let mode else { return nil }
        let report = board.report
        switch row {
        case .banner:
            return SportsPillConfiguration(symbol: "wifi.exclamationmark", tint: .systemOrange, title: SportsCopy.unreachableTitle, detail: failure ?? SportsCopy.unreachableBody, progress: nil, working: false, action: String(localized: "Try Again"))
        case .hero:
            if let hero = board.hero {
                return SportsHeroConfiguration(label: SportsCopy.latest, file: hero.fileName, title: SportsItemLabel.title(hero), meta: SportsCopy.meta(hero), posterPath: hero.posterPath, posterWords: hero.posterWords, isExample: false, playsChange: true)
            }
            let words = SportsPosterWords(event: SportsCopy.exampleTitle, part: nil, headline: "")
            return SportsHeroConfiguration(label: SportsCopy.example, file: SportsCopy.exampleFile, title: SportsCopy.exampleTitle, meta: SportsCopy.transformationLine, posterPath: nil, posterWords: words, isExample: true, playsChange: true)
        case .pill:
            return pillConfiguration(board, mode)
        case .live:
            guard let current = report.status.current else { return nil }
            return SportsLiveConfiguration(
                phase: SportsCopy.phase(report.status),
                name: current.name,
                file: current.file,
                posterPath: "/library/metadata/\(current.ratingKey)/thumb",
                model: report.model?.name,
                elapsed: current.elapsed,
                receivedAt: receivedAt,
                steps: current.newestSteps(5),
                waiting: report.status.queued > 0 ? SportsCopy.queued(report.status.queued) : nil,
                lastLooked: nil
            )
        case .step(let group):
            guard let step = board.steps.first(where: { $0.group == group }) else { return nil }
            return SportsStepConfiguration(step: step, total: board.steps.count, expanded: openGroup == group, owner: report.owner, settings: report.settings, libraries: report.libraries, busy: busy, actions: stepActions(group))
        default:
            return nil
        }
    }

    private func pillConfiguration(_ board: SportsBoard, _ mode: SportsMode) -> SportsPillConfiguration {
        let report = board.report
        let status = report.status
        let lastLooked = status.lastPass.map { SportsCopy.lastLooked(Date(timeIntervalSince1970: TimeInterval($0))) }
        let progress = Double(board.doneCount) / Double(max(1, board.total))
        switch mode {
        case .notPro:
            return SportsPillConfiguration(symbol: "lock.fill", tint: Theme.Color.accent, title: SportsCopy.proPitch, detail: "", progress: nil, working: false, action: SportsCopy.seePro)
        case .viewer:
            return SportsPillConfiguration(symbol: status.isWorking ? "waveform" : "eye", tint: Theme.Color.accent, title: SportsCopy.phase(status), detail: SportsCopy.ownerOnly, progress: nil, working: status.isWorking, action: nil)
        case .setup:
            return SportsPillConfiguration(symbol: "list.number", tint: Theme.Color.accent, title: SportsCopy.setUpInFour, detail: SportsCopy.progress(done: board.doneCount, of: board.total), progress: progress, working: false, action: showsSetup ? SportsCopy.hideSetup : SportsCopy.showSetup)
        case .onlySwitch:
            return SportsPillConfiguration(symbol: "power", tint: Theme.Color.accent, title: SportsCopy.oneSwitch, detail: SportsCopy.progress(done: board.doneCount, of: board.total), progress: progress, working: false, action: showsSetup ? SportsCopy.hideSetup : SportsCopy.showSetup)
        case .ready:
            if let error = status.lastError, !error.isEmpty, !status.isWorking {
                return SportsPillConfiguration(symbol: "exclamationmark.triangle.fill", tint: .systemOrange, title: SportsCopy.phase(status), detail: error, progress: nil, working: false, action: showsSetup ? SportsCopy.hideSetup : SportsCopy.showSetup)
            }
            let detail = [status.isWorking ? nil : SportsCopy.phase(status), lastLooked].compactMap { $0 }.joined(separator: " · ")
            return SportsPillConfiguration(symbol: "checkmark.seal.fill", tint: Theme.Color.statusOK, title: SportsCopy.allReady, detail: detail, progress: nil, working: false, action: showsSetup ? SportsCopy.hideSetup : SportsCopy.showSetup)
        }
    }

    private func stepActions(_ group: SportsRequirement.Group) -> SportsStepActions {
        SportsStepActions(
            toggle: { [weak self] in
                guard let self else { return }
                expansion = openGroup == group ? .none : .group(group)
                Haptics.selection()
                applySnapshot(animated: true)
            },
            copy: { command in
                UIPasteboard.general.string = command
                Haptics.success()
            },
            share: { [weak self] command, view in
                let sheet = UIActivityViewController(activityItems: [command], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = view
                self?.present(sheet, animated: true)
            },
            agree: { [weak self] in self?.askToAgree() },
            library: { [weak self] library in self?.toggle(library) },
            switchOn: { [weak self] in self?.setOn(true) }
        )
    }
}

// MARK: Choices

extension SportsResearchViewController {
    private func listConfiguration(_ row: Row) -> UIContentConfiguration? {
        guard let report = board?.report else { return nil }
        switch row {
        case .empty:
            return IconRowContentConfiguration(symbol: filter == .needsALook ? "checkmark.circle" : "tray", title: filter == .needsALook ? SportsCopy.nothingNeedsALook : SportsCopy.nothingYet)
        case .choice(.on):
            return IconRowContentConfiguration(symbol: "power", title: SportsCopy.researchNewFiles, toggle: .init(isOn: report.settings.on, isEnabled: !busy) { [weak self] wanted in self?.setOn(wanted) })
        case .choice(.library(let key)):
            return IconRowContentConfiguration(symbol: "film.stack", title: report.libraries.first { $0.key == key }?.title ?? key, isActionable: true)
        case .choice(.agreement):
            return IconRowContentConfiguration(symbol: report.settings.agreed ? "hand.raised.slash" : "hand.raised", symbolColor: report.settings.agreed ? Theme.Color.labelSecondary : .systemOrange, title: report.settings.agreed ? SportsCopy.withdraw : SportsCopy.agree, isActionable: true)
        case .choice(.checkAgain):
            return IconRowContentConfiguration(symbol: "arrow.triangle.2.circlepath", title: SportsCopy.checkAgain, subtitle: busy ? CompanionCopy.checking : nil, isActionable: true)
        case .choice(.lookNow):
            return IconRowContentConfiguration(symbol: "magnifyingglass", title: SportsCopy.lookNow, isActionable: true)
        case .how(let index):
            let step = SportsCopy.howSteps[index]
            return IconRowContentConfiguration(symbol: step.symbol, symbolColor: Theme.Color.accent, title: step.title, subtitle: step.detail)
        default:
            return nil
        }
    }

    private func accessories(_ row: Row) -> [UICellAccessory] {
        guard case .choice(.library(let key)) = row, board?.report.libraries.first(where: { $0.key == key })?.chosen == true else { return [] }
        return [.checkmark(options: .init(tintColor: Theme.Color.accent))]
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .result, .banner: true
        case .pill: mode != .viewer
        case .choice(.library), .choice(.agreement), .choice(.checkAgain), .choice(.lookNow): !busy
        default: false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let board else { return }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .result(let key):
            if let item = board.report.items.first(where: { $0.ratingKey == key }) { open(item) }
        case .pill:
            switch mode {
            case .notPro?: ProAccess.shared.requestUnlock(.sportsResearch) { [weak self] _ in self?.applySnapshot() }
            case .setup?, .onlySwitch?, .ready?:
                setupShown = !showsSetup
                Haptics.selection()
                applySnapshot(animated: true)
            default: break
            }
        case .banner: startRefreshing()
        case .choice(.library(let key)):
            if let library = board.report.libraries.first(where: { $0.key == key }) { toggle(library) }
        case .choice(.agreement): board.report.settings.agreed ? change(agree: false) : askToAgree()
        case .choice(.checkAgain): perform { source throws(CompanionError) in try await source.recheckSports() }
        case .choice(.lookNow): perform { source throws(CompanionError) in try await source.runSports() }
        default: break
        }
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard !busy, mode == .ready || mode == .setup || mode == .onlySwitch, let indexPath = indexPaths.first, case .result(let key) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(title: SportsCopy.researchAgain, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.redo(key) }])
        })
    }

    private func open(_ item: SportsItem) {
        let canRedo = !busy && (mode == .ready || mode == .setup || mode == .onlySwitch)
        let detail = SportsItemViewController(item: item, canRedo: canRedo) { [weak self] in self?.redo(item.ratingKey) }
        let navigation = UINavigationController(rootViewController: detail)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(navigation, animated: true)
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

    private func redo(_ key: String) {
        perform { source throws(CompanionError) in try await source.redoSports(ratingKey: key) }
    }

    private func change(on: Bool? = nil, libraries: [String]? = nil, agree: Bool? = nil) {
        guard !busy else { return }
        if let board { self.board = SportsBoard(report: board.report.expecting(on: on, libraries: libraries, agree: agree)) }
        perform { source throws(CompanionError) in try await source.changeSports(on: on, libraries: libraries, agree: agree) }
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
                if let self { CompanionPairingFlow.show(error.message, from: self) }
            }
            self?.busy = false
            await self?.load()
            self?.resumeRefreshingIfShown()
        }
    }
}

/// The results heading: the title with the counts, and the choice between every result and the ones that need a look.
final class SportsResultsHeader: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let countsLabel = UILabel()
    private let segments = UISegmentedControl()
    private var onChange: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = Theme.Font.title3
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.accessibilityTraits = .header
        countsLabel.font = Theme.Font.footnote
        countsLabel.adjustsFontForContentSizeCategory = true
        countsLabel.textColor = Theme.Color.labelSecondary
        countsLabel.numberOfLines = 0
        segments.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(segments.selectedSegmentIndex)
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [titleLabel, countsLabel, segments])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.xxs
        stack.setCustomSpacing(Theme.Space.s, after: countsLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xs),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, counts: String, needing: Int, filter: Int, onChange: @escaping (Int) -> Void) {
        titleLabel.text = title
        countsLabel.text = counts
        self.onChange = onChange
        let needs = needing > 0 ? "\(SportsCopy.needsALook) · \(needing)" : SportsCopy.needsALook
        if segments.numberOfSegments == 2 {
            segments.setTitle(needs, forSegmentAt: 1)
        } else {
            segments.removeAllSegments()
            segments.insertSegment(withTitle: SportsCopy.all, at: 0, animated: false)
            segments.insertSegment(withTitle: needs, at: 1, animated: false)
        }
        segments.selectedSegmentIndex = filter
        segments.isHidden = needing == 0 && filter == 0
        segments.accessibilityIdentifier = "settings.sports.filter"
    }
}
