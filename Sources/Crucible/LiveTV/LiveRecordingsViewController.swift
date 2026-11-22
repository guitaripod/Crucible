import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// Live TV › Recordings: what the server is recording now and will record, and the standing rules; swipe or tap to cancel a
/// recording or delete a rule.
final class LiveRecordingsViewController: UICollectionViewController {
    private enum Section: Int { case scheduled, rules, message }

    private enum Row: Hashable {
        case recording(String)
        case rule(String)
        case message(String)
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var scheduled: [ScheduledRecording] = []
    private var rules: [RecordingRule] = []
    private var failure: String?
    private var observer: NSObjectProtocol?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = LiveTVCopy.recordings
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "livetv.recordings"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = .supplementary
            config.trailingSwipeActionsConfigurationProvider = { indexPath in self?.swipeActions(at: indexPath) }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader().textSized()
            switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .scheduled?: content.text = LiveTVCopy.scheduled
            case .rules?: content.text = LiveTVCopy.rules
            default: content.text = nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        observer = NotificationCenter.default.addObserver(forName: .liveRecordingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        load()
    }

    private func load() {
        let api = api
        Task { [weak self] in
            do {
                async let scheduled = LiveRecordings.scheduled(api: api)
                async let rules = LiveRecordings.rules(api: api)
                let (found, standing) = try await (scheduled, rules)
                self?.scheduled = found.filter { $0.status != .complete }
                self?.rules = standing
                self?.failure = nil
            } catch {
                self?.failure = LiveTVCopy.recordingError(error)
            }
            self?.collectionView.refreshControl?.endRefreshing()
            self?.applySnapshot()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        if let failure {
            snapshot.appendSections([.message])
            snapshot.appendItems([.message(failure)], toSection: .message)
        } else if scheduled.isEmpty, rules.isEmpty {
            snapshot.appendSections([.message])
            snapshot.appendItems([.message(LiveTVCopy.noRecordingsText)], toSection: .message)
        } else {
            if !scheduled.isEmpty {
                snapshot.appendSections([.scheduled])
                snapshot.appendItems(scheduled.map { .recording($0.id) }, toSection: .scheduled)
            }
            if !rules.isEmpty {
                snapshot.appendSections([.rules])
                snapshot.appendItems(rules.map { .rule($0.id) }, toSection: .rules)
            }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        switch row {
        case .recording(let id):
            guard let recording = scheduled.first(where: { $0.id == id }) else { return }
            let status: String = switch recording.status {
            case .recording: LiveTVCopy.recordingNow
            case .failed: LiveTVCopy.failedStatus
            default: recording.start.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            }
            let subtitle = [recording.episodeTitle, recording.channel].compactMap { $0 }.joined(separator: " · ")
            var content = IconRowContentConfiguration(symbol: recording.status == .recording ? "record.circle.fill" : "calendar", title: recording.title,
                                                      subtitle: subtitle.isEmpty ? nil : subtitle, value: status)
            content.symbolColor = recording.status == .recording ? Theme.Color.destructive : nil
            content.isActionable = true
            cell.contentConfiguration = content
        case .rule(let id):
            guard let rule = rules.first(where: { $0.id == id }) else { return }
            var content = IconRowContentConfiguration(symbol: "repeat", title: rule.title, subtitle: [rule.airings, rule.library].compactMap { $0 }.joined(separator: " · "),
                                                      value: rule.isSeries ? LiveTVCopy.recordSeries : LiveTVCopy.recordEpisode)
            content.isActionable = true
            cell.contentConfiguration = content
        case .message(let text):
            var content = UIListContentConfiguration.cell().textSized()
            content.text = LiveTVCopy.noRecordings
            content.secondaryText = text
            content.textProperties.font = Theme.Font.headline
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .recording(let id)?:
            guard let recording = scheduled.first(where: { $0.id == id }) else { return nil }
            return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: LiveTVCopy.cancelRecording) { [weak self] _, _, done in
                self?.perform { try await LiveRecordings.cancel(recording, api: $0) }
                done(true)
            }])
        case .rule(let id)?:
            return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: LiveTVCopy.deleteRule) { [weak self] _, _, done in
                self?.confirmDelete(ruleID: id)
                done(true)
            }])
        default:
            return nil
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .recording(let id)?:
            guard let recording = scheduled.first(where: { $0.id == id }) else { return }
            let sheet = UIAlertController(title: recording.title, message: recording.episodeTitle, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: LiveTVCopy.cancelRecording, style: .destructive) { [weak self] _ in
                self?.perform { try await LiveRecordings.cancel(recording, api: $0) }
            })
            sheet.addAction(UIAlertAction(title: String(localized: "Close"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = collectionView.cellForItem(at: indexPath)
            present(sheet, animated: true)
        case .rule(let id)?:
            confirmDelete(ruleID: id)
        default:
            break
        }
    }

    private func confirmDelete(ruleID: String) {
        let alert = UIAlertController(title: LiveTVCopy.deleteRuleQuestion, message: LiveTVCopy.deleteRuleText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: LiveTVCopy.deleteRule, style: .destructive) { [weak self] _ in
            self?.perform { try await LiveRecordings.deleteRule(ruleID, api: $0) }
        })
        present(alert, animated: true)
    }

    private func perform(_ change: @escaping @Sendable (APIClient) async throws -> Void) {
        let api = api
        Task { [weak self] in
            do {
                try await change(api)
                Haptics.success()
            } catch {
                let alert = UIAlertController(title: LiveTVCopy.recordingError(error), message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                self?.present(alert, animated: true)
            }
        }
    }
}
