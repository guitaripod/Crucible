import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// Looks for subtitles for one title through the server and keeps the one the viewer picks. The language is a menu in the bar; a row
/// shows what the match is and where it comes from.
final class SubtitleSearchViewController: UICollectionViewController {
    private let api: APIClient
    private let ratingKey: String
    private let onDownloaded: () -> Void
    private var language = SubtitleLanguages.defaultCode()
    private var candidates: [PlexSubtitleCandidate] = []
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var searchTask: Task<Void, Never>?
    private var isDownloading = false

    init(api: APIClient, ratingKey: String, onDownloaded: @escaping () -> Void) {
        self.api = api
        self.ratingKey = ratingKey
        self.onDownloaded = onDownloaded
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = Theme.Color.canvas
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { searchTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SubtitleSearch.screenTitle
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        configureDataSource()
        refreshLanguageButton()
        search()
    }

    private func refreshLanguageButton() {
        let actions = SubtitleLanguages.codes.map { code in
            UIAction(title: SubtitleLanguages.name(for: code), state: code == language ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.language = code
                self?.refreshLanguageButton()
                self?.search()
            }
        }
        let item = UIBarButtonItem(
            title: SubtitleLanguages.name(for: language),
            menu: UIMenu(title: SubtitleSearch.languageTitle, children: actions)
        )
        item.accessibilityLabel = String(localized: "\(SubtitleSearch.languageTitle), \(SubtitleLanguages.name(for: language))")
        item.accessibilityIdentifier = "subtitles.language"
        navigationItem.rightBarButtonItem = item
    }

    private func search() {
        searchTask?.cancel()
        candidates = []
        apply()
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await SubtitleSearch.search(ratingKey: ratingKey, language: language, api: api)
                guard !Task.isCancelled else { return }
                candidates = found
                apply()
                contentUnavailableConfiguration = found.isEmpty ? emptyConfiguration() : nil
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Subtitle search failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
                contentUnavailableConfiguration = failureConfiguration(error.localizedDescription)
            }
        }
    }

    private func emptyConfiguration() -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "captions.bubble")
        config.text = SubtitleSearch.emptyTitle
        config.secondaryText = SubtitleSearch.emptyText
        return config
    }

    private func failureConfiguration(_ message: String) -> UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = String(localized: "Couldn\u{2019}t Load")
        config.secondaryText = message
        var button = UIButton.Configuration.filled()
        button.title = String(localized: "Retry")
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        button.cornerStyle = .capsule
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.search() }
        return config
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, key in
            guard let candidate = self?.candidates.first(where: { $0.key == key }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = candidate.title ?? SubtitleLanguages.name(for: candidate.languageCode ?? self?.language ?? "")
            content.secondaryText = SubtitleSearch.detail(candidate)
            content.textProperties.font = Theme.Font.body
            content.textProperties.color = Theme.Color.label
            content.secondaryTextProperties.font = Theme.Font.footnote
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            content.image = UIImage(systemName: candidate.perfectMatch ? "star.fill" : "captions.bubble")
            content.imageProperties.tintColor = candidate.perfectMatch ? Theme.Color.accent : Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .listGroupedCell()
            cell.accessibilityIdentifier = "subtitles.candidate.\(key)"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, key in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: key)
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(candidates.map(\.key), toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard !isDownloading, let key = dataSource.itemIdentifier(for: indexPath),
              let candidate = candidates.first(where: { $0.key == key }) else { return }
        download(candidate)
    }

    private func download(_ candidate: PlexSubtitleCandidate) {
        isDownloading = true
        collectionView.isUserInteractionEnabled = false
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await SubtitleSearch.download(candidate, ratingKey: ratingKey, language: language, api: api)
                Haptics.success()
                onDownloaded()
                dismiss(animated: true)
            } catch {
                Haptics.error()
                isDownloading = false
                collectionView.isUserInteractionEnabled = true
                contentUnavailableConfiguration = nil
                presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Download"), message: error.localizedDescription)
            }
        }
    }
}
