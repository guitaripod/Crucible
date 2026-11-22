import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Library Research › Schedule: the week's hours as a grid to tap and paint, with ready-made schedules under it. Every
/// change goes to the server by itself a moment after the owner stops, and once more as they leave.
final class SportsScheduleViewController: UICollectionViewController {
    private enum Section: Hashable {
        case grid, presets
    }

    private enum Row: Hashable {
        case grid
        case preset(SportsSchedule.Preset)
        case custom
    }

    private let source: any SportsSource
    private let settings: SportsSettings
    private let onSaved: (SportsSchedule?) -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var schedule: SportsSchedule
    private var saved: SportsSchedule
    private var saveTask: Task<Void, Never>?

    init(source: any SportsSource, settings: SportsSettings, onSaved: @escaping (SportsSchedule?) -> Void) {
        self.source = source
        self.settings = settings
        self.onSaved = onSaved
        schedule = settings.schedule ?? .always
        saved = schedule
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SportsCopy.schedule
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "settings.sports.schedule"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = .supplementary
            config.footerMode = .supplementary
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.grid, .presets])
        snapshot.appendItems([.grid], toSection: .grid)
        snapshot.appendItems(SportsSchedule.Preset.allCases.map(Row.preset) + [.custom], toSection: .presets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in await self?.save() }
    }

    // MARK: Data source

    private func configureDataSource() {
        let gridCell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = SportsWeekGridConfiguration(schedule: schedule, now: now, onChange: { [weak self] changed in
                self?.changed(to: changed, fromGrid: true)
            }, onCommit: { [weak self] _ in
                self?.saveSoon()
            })
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "settings.sports.schedule.grid"
        }
        let rowCell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            cell.contentConfiguration = rowConfiguration(row)
            cell.accessories = isChosen(row) ? [.checkmark(options: .init(tintColor: Theme.Color.accent))] : []
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "settings.sports.schedule.\(identifier(row))"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            row == .grid
                ? collectionView.dequeueConfiguredReusableCell(using: gridCell, for: indexPath, item: row)
                : collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .grid ? SportsCopy.hoursHeader : SportsCopy.readyMade
            content.textProperties.font = Theme.Font.footnote
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, indexPath in
            cell.contentConfiguration = self?.footer(self?.dataSource.sectionIdentifier(for: indexPath.section))
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private var now: (day: Int, hour: Int)? {
        guard let day = settings.weekday, let hour = settings.hour else { return nil }
        return (day, hour)
    }

    private func isChosen(_ row: Row) -> Bool {
        switch row {
        case .preset(let preset): schedule.preset == preset
        case .custom: schedule.preset == nil
        case .grid: false
        }
    }

    private func rowConfiguration(_ row: Row) -> UIContentConfiguration? {
        switch row {
        case .preset(let preset):
            return IconRowContentConfiguration(symbol: preset.symbol, title: SportsCopy.preset(preset), subtitle: preset == .anyTime ? nil : SportsCopy.summary(preset.schedule), isActionable: true)
        case .custom:
            let custom = schedule.preset == nil
            return IconRowContentConfiguration(symbol: "slider.horizontal.3", title: SportsCopy.custom, subtitle: custom ? SportsCopy.summary(schedule) : SportsCopy.gridHint, isActionable: false)
        case .grid:
            return nil
        }
    }

    /// Under the grid: how to use it, the hours a week and the server's clock, or why there is nothing to save. Under the
    /// ready-made schedules: what a schedule does.
    private func footer(_ section: Section?) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.groupedFooter()
        content.textProperties.font = Theme.Font.caption1Regular
        content.textProperties.color = Theme.Color.labelSecondary
        guard section == .grid else {
            content.text = SportsCopy.scheduleExplanation
            return content
        }
        if schedule.isEmpty {
            content.text = SportsCopy.chooseAnHour
            content.textProperties.color = .systemOrange
            return content
        }
        content.text = [SportsCopy.hoursAWeek(schedule.hours), SportsCopy.clockNote(settings)].compactMap { $0 }.joined(separator: " · ")
        return content
    }

    private func identifier(_ row: Row) -> String {
        switch row {
        case .preset(let preset): "preset.\(preset.rawValue)"
        case .custom: "custom"
        case .grid: "grid"
        }
    }

    // MARK: Changes

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        if case .preset = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .preset(let preset) = dataSource.itemIdentifier(for: indexPath), schedule != preset.schedule else { return }
        Haptics.selection()
        changed(to: preset.schedule, fromGrid: false)
        saveSoon(after: 0)
    }

    /// Shows a new schedule everywhere but in the grid while a finger paints it, which shows it already.
    private func changed(to changed: SportsSchedule, fromGrid: Bool) {
        schedule = changed
        var snapshot = dataSource.snapshot()
        let rows = fromGrid ? snapshot.itemIdentifiers(inSection: .presets) : snapshot.itemIdentifiers
        snapshot.reconfigureItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
        for case let footer as UICollectionViewListCell in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter) {
            guard let indexPath = collectionView.indexPath(forSupplementaryView: footer) else { continue }
            footer.contentConfiguration = self.footer(dataSource.sectionIdentifier(for: indexPath.section))
        }
    }

    /// Sends the schedule a moment after the last change, so a few quick taps go as one.
    private func saveSoon(after delay: Double = 0.8) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private func save() async {
        saveTask = nil
        let wanted = schedule
        guard !wanted.isEmpty, wanted != saved else { return }
        do throws(CompanionError) {
            try await source.scheduleSports(wanted.isAlways ? nil : wanted)
            saved = wanted
            onSaved(wanted.isAlways ? nil : wanted)
        } catch {
            Haptics.error()
            if viewIfLoaded?.window != nil {
                CompanionPairingFlow.show(error.message, from: self)
            }
        }
    }
}

/// The week's grid as a list cell's content.
struct SportsWeekGridConfiguration: UIContentConfiguration {
    var schedule: SportsSchedule
    var now: (day: Int, hour: Int)?
    var onChange: (SportsSchedule) -> Void
    var onCommit: (SportsSchedule) -> Void

    func makeContentView() -> UIView & UIContentView {
        SportsWeekGridContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SportsWeekGridConfiguration {
        self
    }
}

private final class SportsWeekGridContentView: UIView, UIContentView {
    private let grid = SportsWeekGridView(editable: true)

    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: SportsWeekGridConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let configuration = configuration as? SportsWeekGridConfiguration else { return }
        grid.onChange = configuration.onChange
        grid.onCommit = configuration.onCommit
        grid.show(configuration.schedule)
        grid.now = configuration.now
    }
}
