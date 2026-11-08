import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The Request sheet: a title the server does not have, or a show missing seasons, and where it stands in Seerr. Requesting
/// a title the server does not have also puts it on the Plex watchlist, so Watchlist Arrivals says when it lands.
final class SeerrRequestViewController: UICollectionViewController {
    private enum Section: Int {
        case header, seasons, action
    }

    private enum Row: Hashable {
        case header
        case loading
        case message(String)
        case season(Int)
        case allSeasonsNote
        case request
        case withdraw
        case play
        case watchlistNote
    }

    private let item: PlexMetadata
    private let api: APIClient
    private let isOnServer: Bool
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var state: SeerrTitleState?
    private var failure: String?
    private var selected = Set<Int>()
    private var isWorking = false
    private var addedToWatchlist = false
    private var poster: UIImage?

    /// - Parameter isOnServer: whether `item` comes from the server, which knows its ids, rather than from the watchlist.
    init(item: PlexMetadata, api: APIClient, isOnServer: Bool) {
        self.item = item
        self.api = api
        self.isOnServer = isOnServer
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the sheet for `item` from `host`, or says how to set requests up when Seerr is not connected.
    static func present(for item: PlexMetadata, api: APIClient, isOnServer: Bool, from host: UIViewController?) {
        guard let host else { return }
        guard SeerrAccount.shared.isConnected else {
            let message = isOnServer ? SeerrCopy.notConnectedMessage : WatchlistService.notInLibraryText + "\n\n" + SeerrCopy.notConnectedMessage
            presentSetUp(title: isOnServer ? SeerrCopy.notConnectedTitle : WatchlistService.notInLibraryTitle, message: message, api: api, from: host)
            return
        }
        let sheet = SeerrRequestViewController(item: item, api: api, isOnServer: isOnServer)
        let navigation = UINavigationController(rootViewController: sheet)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.selectedDetentIdentifier = item.mediaType == "show" ? .large : .medium
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        host.present(navigation, animated: true)
    }

    private static func presentSetUp(title: String, message: String, api: APIClient, from host: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SeerrCopy.setUp, style: .default) { [weak host] _ in
            let settings = SeerrSettingsViewController(api: api)
            if let navigation = host?.navigationController {
                navigation.pushViewController(settings, animated: true)
            } else {
                host?.present(UINavigationController(rootViewController: settings), animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        host.present(alert, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SeerrCopy.requestTitle
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityIdentifier = "seerr.request.close"
        navigationItem.rightBarButtonItem = close
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "seerr.request"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = self?.dataSource?.sectionIdentifier(for: index) == .seasons ? .supplementary : .none
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        applySnapshot()
        loadPoster()
        load(refresh: false)
    }

    private func load(refresh: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let state = try await SeerrTitles.shared.state(for: item, api: isOnServer ? api : nil, refresh: refresh) else {
                    failure = SeerrCopy.notIdentified
                    return applySnapshot()
                }
                self.state = state
                failure = nil
                selected = Set(state.requestableSeasons)
            } catch {
                failure = error.localizedDescription
            }
            applySnapshot()
        }
    }

    private func loadPoster() {
        guard let thumb = item.thumb else { return }
        Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: thumb, width: 300)
            guard let self else { return }
            poster = image
            applySnapshot()
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header], toSection: .header)
        defer {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        if let failure {
            snapshot.appendItems([.message(failure)], toSection: .header)
            return
        }
        guard let state else {
            snapshot.appendItems([.loading], toSection: .header)
            return
        }
        if state.kind == .tv, !state.seasons.isEmpty {
            snapshot.appendSections([.seasons])
            snapshot.appendItems(state.seasons.map { .season($0.number) }, toSection: .seasons)
            if !(SeerrAccount.shared.connection?.partialRequests ?? true), !state.requestableSeasons.isEmpty {
                snapshot.appendItems([.allSeasonsNote], toSection: .seasons)
            }
        }
        var actions: [Row] = []
        if let ratingKey = state.ratingKey, ratingKey != item.ratingKey, state.availability == .available || state.availability == .partiallyAvailable {
            actions.append(.play)
        }
        if state.canRequest(with: SeerrAccount.shared.permissions) { actions.append(.request) }
        if state.ownPendingRequest != nil { actions.append(.withdraw) }
        if addedToWatchlist { actions.append(.watchlistNote) }
        if !SeerrAccount.shared.permissions.canRequest(state.kind), state.availability == .notRequested {
            actions.append(.message(SeerrError.notAllowed.localizedDescription))
        }
        if !actions.isEmpty {
            snapshot.appendSections([.action])
            snapshot.appendItems(actions, toSection: .action)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, _ in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = SeerrCopy.chooseSeasons
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        cell.accessories = []
        cell.applyThemedBackground()
        cell.accessibilityTraits = []
        switch row {
        case .header:
            cell.contentConfiguration = SeerrTitleHeaderConfiguration(
                title: state?.title ?? item.title,
                year: state?.year ?? item.year,
                availability: state?.availability,
                overview: state?.overview ?? item.summary,
                poster: poster
            )
            cell.backgroundConfiguration = .clear()
        case .loading:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "tray.and.arrow.down", title: String(localized: "Loading"))
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        case .message(let text):
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "info.circle", title: text)
            cell.accessibilityIdentifier = "seerr.request.message"
        case .season(let number):
            guard let season = state?.seasons.first(where: { $0.number == number }) else { break }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = SeerrCopy.seasonName(season)
            content.secondaryText = [SeerrCopy.seasonStatus(season.status), season.episodeCount.map { String(localized: "\($0) episodes", comment: "Number of episodes in a season") }].compactMap { $0 }.joined(separator: " · ")
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            let requestable = season.status == .missing
            content.textProperties.color = requestable ? Theme.Color.label : Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "seerr.season.\(number)"
            if requestable {
                let isChosen = selected.contains(number) || !(SeerrAccount.shared.connection?.partialRequests ?? true)
                let mark = UIImageView(image: UIImage(systemName: isChosen ? "checkmark.circle.fill" : "circle"))
                mark.tintColor = isChosen ? Theme.Color.accent : Theme.Color.labelTertiary
                cell.accessories = [.customView(configuration: .init(customView: mark, placement: .trailing()))]
                cell.accessibilityTraits = isChosen ? [.button, .selected] : .button
            } else {
                cell.accessories = [.customView(configuration: .init(customView: Self.statusIcon(season.status), placement: .trailing()))]
                cell.accessibilityTraits = .staticText
            }
        case .allSeasonsNote:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "info.circle", title: SeerrCopy.onlyAllSeasons)
        case .request:
            cell.contentConfiguration = Self.button(requestTitle, color: canSubmit ? Theme.Color.accentText : Theme.Color.labelTertiary, bold: true, working: isWorking)
            cell.accessibilityIdentifier = "seerr.request.submit"
            cell.accessibilityTraits = canSubmit ? .button : [.button, .notEnabled]
        case .withdraw:
            cell.contentConfiguration = Self.button(SeerrCopy.withdraw, color: Theme.Color.destructive, bold: false, working: false)
            cell.accessibilityIdentifier = "seerr.request.withdraw"
            cell.accessibilityTraits = .button
        case .play:
            cell.contentConfiguration = Self.button(SeerrCopy.play, color: Theme.Color.accentText, bold: true, working: false)
            cell.accessibilityIdentifier = "seerr.request.play"
            cell.accessibilityTraits = .button
        case .watchlistNote:
            var content = UIListContentConfiguration.cell()
            content.image = UIImage(systemName: "bookmark.fill")
            content.imageProperties.tintColor = Theme.Color.accent
            content.text = SeerrCopy.alsoWatchlist
            content.textProperties.font = Theme.Font.subheadline
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "seerr.request.watchlisted"
        }
    }

    private var requestTitle: String {
        guard let state, state.kind == .tv else { return SeerrCopy.request }
        let partial = SeerrAccount.shared.connection?.partialRequests ?? true
        let count = partial ? selected.count : state.requestableSeasons.count
        guard count > 0, count != state.seasons.count else { return SeerrCopy.request }
        return SeerrCopy.requestSeasons(count)
    }

    private var canSubmit: Bool {
        guard let state, !isWorking else { return false }
        if state.kind == .tv, SeerrAccount.shared.connection?.partialRequests ?? true { return !selected.isEmpty }
        return true
    }

    private static func statusIcon(_ status: SeerrSeasonState.Status) -> UIImageView {
        let symbol: String
        switch status {
        case .available: symbol = "play.circle"
        case .partiallyAvailable: symbol = "circle.lefthalf.filled"
        case .processing: symbol = "arrow.down.circle"
        case .requested: symbol = "hourglass"
        case .missing: symbol = "circle"
        }
        let view = UIImageView(image: UIImage(systemName: symbol))
        view.tintColor = Theme.Color.labelSecondary
        return view
    }

    private static func button(_ title: String, color: UIColor, bold: Bool, working: Bool) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = working ? SeerrCopy.requesting : title
        content.textProperties.font = bold ? Theme.Font.headline : Theme.Font.body
        content.textProperties.color = color
        content.textProperties.alignment = .center
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16)
        return content
    }

    // MARK: - Selection

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .season(let number):
            let partial = SeerrAccount.shared.connection?.partialRequests ?? true
            return partial && state?.requestableSeasons.contains(number) == true
        case .request: return canSubmit
        case .withdraw, .play: return !isWorking
        default: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .season(let number):
            collectionView.deselectItem(at: indexPath, animated: true)
            Haptics.selection()
            if selected.contains(number) { selected.remove(number) } else { selected.insert(number) }
            reconfigureRequest()
        case .request:
            collectionView.deselectItem(at: indexPath, animated: true)
            submit()
        case .withdraw:
            collectionView.deselectItem(at: indexPath, animated: true)
            withdraw()
        case .play:
            collectionView.deselectItem(at: indexPath, animated: true)
            play()
        default:
            collectionView.deselectItem(at: indexPath, animated: false)
        }
    }

    private func reconfigureRequest() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { row in
            if case .season = row { return true }
            return row == .request
        })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    private func submit() {
        guard let state, canSubmit else { return }
        isWorking = true
        applySnapshot()
        let seasons = state.kind == .tv ? Array(selected).sorted() : nil
        Task { [weak self] in
            guard let self else { return }
            do {
                self.state = try await SeerrTitles.shared.request(state, seasons: seasons)
                Haptics.success()
                selected = Set(self.state?.requestableSeasons ?? [])
                isWorking = false
                applySnapshot()
                if !isOnServer, let guid = item.guid {
                    await addToWatchlist(guid)
                    applySnapshot()
                }
            } catch {
                Haptics.error()
                isWorking = false
                applySnapshot()
                presentSimpleAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
        }
    }

    private func addToWatchlist(_ guid: String) async {
        let token = api.token
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

    /// The navigation stack the sheet was opened over, to push the arrived title onto.
    private static func navigation(of presenter: UIViewController?) -> UINavigationController? {
        if let navigation = presenter as? UINavigationController { return navigation }
        if let tabs = presenter as? UITabBarController { return tabs.selectedViewController as? UINavigationController }
        return presenter?.navigationController
    }

    private func withdraw() {
        guard let state, let request = state.ownPendingRequest else { return }
        isWorking = true
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                self.state = try await SeerrTitles.shared.withdraw(request, of: state)
                selected = Set(self.state?.requestableSeasons ?? [])
                Haptics.light()
            } catch {
                Haptics.error()
                presentSimpleAlert(title: SeerrCopy.connectFailed, message: error.localizedDescription)
            }
            isWorking = false
            applySnapshot()
        }
    }

    private func play() {
        guard let ratingKey = state?.ratingKey else { return }
        let presenter = presentingViewController
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let local = try await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first else { return }
                dismiss(animated: true) {
                    HomeMediaActions.openDetail(local, api: self.api, from: Self.navigation(of: presenter))
                }
            } catch {
                presentSimpleAlert(title: String(localized: "Couldn\u{2019}t Load"), message: error.localizedDescription)
            }
        }
    }
}
