import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// Live TV's settings and the viewer's channel playlists: Show Live TV (from Settings), Plex's free channels, each playlist
/// opening its page, Add Playlist and Refresh Channels. Adding asks for the address (taking one from the clipboard), reads
/// the playlist to check it and names it after its host; the guide address comes from the playlist itself unless given.
final class LivePlaylistsViewController: UICollectionViewController {
    private enum Row: Hashable {
        case destination
        case plexChannels
        case mergeDuplicates
        case playlist(String)
        case add
        case refresh
        case note
    }

    private let showsDestinationSwitch: Bool
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private var isChecking = false
    private var observer: NSObjectProtocol?
    private var pendingAdd = false

    init(showsDestinationSwitch: Bool) {
        self.showsDestinationSwitch = showsDestinationSwitch
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = showsDestinationSwitch ? LiveTVCopy.title : LiveTVCopy.playlists
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "livetv.playlists"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { index, environment in
            let config = UICollectionLayoutListConfiguration.wellRows()
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        observer = NotificationCenter.default.addObserver(forName: .liveSourcesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySnapshot() }
        }
        applySnapshot()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingAdd {
            pendingAdd = false
            presentAdd()
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        if showsDestinationSwitch {
            snapshot.appendSections([0])
            snapshot.appendItems([.destination], toSection: 0)
        }
        snapshot.appendSections([1, 2, 3])
        snapshot.appendItems([.plexChannels, .mergeDuplicates], toSection: 1)
        snapshot.appendItems(LivePlaylistStore.all().map { .playlist($0.id) } + [.add], toSection: 2)
        snapshot.appendItems([.refresh, .note], toSection: 3)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        cell.accessories = []
        switch row {
        case .destination:
            var content = IconRowContentConfiguration(symbol: "antenna.radiowaves.left.and.right", title: LiveTVCopy.showDestination, subtitle: LiveTVCopy.showDestinationFooter)
            content.toggle = .init(isOn: LiveTVPreferences.showsDestination) { isOn in LiveTVPreferences.showsDestination = isOn }
            cell.contentConfiguration = content
        case .plexChannels:
            var content = IconRowContentConfiguration(symbol: "tv", title: LiveTVCopy.showPlexChannels, subtitle: LiveTVCopy.showPlexChannelsFooter)
            content.toggle = .init(isOn: LiveTVPreferences.showsPlexChannels) { isOn in LiveTVPreferences.showsPlexChannels = isOn }
            cell.contentConfiguration = content
        case .mergeDuplicates:
            var content = IconRowContentConfiguration(symbol: "square.on.square", title: LiveTVCopy.mergeDuplicates, subtitle: LiveTVCopy.mergeDuplicatesFooter)
            content.toggle = .init(isOn: LiveTVPreferences.mergesDuplicates) { isOn in LiveTVPreferences.mergesDuplicates = isOn }
            cell.contentConfiguration = content
        case .playlist(let id):
            let playlist = LivePlaylistStore.all().first { $0.id == id }
            var content = IconRowContentConfiguration(symbol: "list.bullet", title: playlist?.name ?? "", subtitle: playlist?.address.host)
            content.isActionable = true
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .add:
            var content = IconRowContentConfiguration(symbol: "plus", title: isChecking ? LiveTVCopy.checkingPlaylist : LiveTVCopy.addPlaylist)
            content.isActionable = !isChecking
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "livetv.addPlaylist"
            if isChecking {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
            }
        case .refresh:
            var content = IconRowContentConfiguration(symbol: "arrow.clockwise", title: LiveTVCopy.refreshPlaylists)
            content.isActionable = true
            cell.contentConfiguration = content
        case .note:
            var content = UIListContentConfiguration.groupedFooter()
            content.text = LiveTVCopy.playlistNote
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .playlist?, .refresh?: return true
        case .add?: return !isChecking
        default: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .playlist(let id)?:
            navigationController?.pushViewController(LivePlaylistViewController(playlistID: id), animated: true)
        case .add?:
            presentAdd()
        case .refresh?:
            Haptics.light()
            LiveTVPreferences.reset()
            NotificationCenter.default.post(name: .liveSourcesChanged, object: nil)
        default:
            break
        }
    }

    /// Asks for a playlist's address, offering the clipboard's when it holds one.
    func presentAdd() {
        guard isViewLoaded, view.window != nil else {
            pendingAdd = true
            return
        }
        let alert = UIAlertController(title: LiveTVCopy.addPlaylist, message: LiveTVCopy.playlistNote, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = LiveTVCopy.playlistAddress
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.textContentType = .URL
            field.accessibilityIdentifier = "livetv.addPlaylist.address"
            if UIPasteboard.general.hasURLs, let url = UIPasteboard.general.url, LivePlaylist.address(from: url.absoluteString) != nil {
                field.text = url.absoluteString
            }
        }
        alert.addTextField { field in
            field.placeholder = LiveTVCopy.guideAddress
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let add = UIAlertAction(title: LiveTVCopy.add, style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let address = LivePlaylist.address(from: alert?.textFields?.first?.text ?? "") else {
                self.notice(LiveTVCopy.invalidAddress)
                return
            }
            let guides = LivePlaylist.addresses(from: alert?.textFields?.last?.text ?? "")
            self.add(LivePlaylist(name: LivePlaylist.suggestedName(for: address), address: address, guideAddresses: guides))
        }
        alert.addAction(add)
        alert.preferredAction = add
        present(alert, animated: true)
    }

    /// Adds `playlist` once it reads as a channel playlist, saying how many channels it has.
    func add(_ playlist: LivePlaylist) {
        isChecking = true
        applySnapshot()
        Task { [weak self] in
            let result = await LivePlaylistCheck.check(playlist)
            guard let self else { return }
            self.isChecking = false
            switch result {
            case .success(let count):
                LivePlaylistStore.save(playlist)
                Haptics.success()
                self.notice(LiveTVCopy.playlistAdded(playlist.name, channels: count))
            case .failure(let message):
                Haptics.error()
                self.notice(LiveTVCopy.failedTitle, message: message)
            }
            self.applySnapshot()
        }
    }

    private func notice(_ title: String, message: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

/// One playlist's page: its name, addresses and user agent, each changed in place, and Remove.
final class LivePlaylistViewController: UICollectionViewController {
    private enum Row: Hashable {
        case name, address, guide, agent, link, remove
    }

    private let playlistID: String
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!

    init(playlistID: String) {
        self.playlistID = playlistID
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var playlist: LivePlaylist? { LivePlaylistStore.all().first { $0.id == playlistID } }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = playlist?.name ?? LiveTVCopy.editPlaylist
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: UICollectionLayoutListConfiguration.wellRows(), layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([.name, .address, .guide, .agent, .link], toSection: 0)
        snapshot.appendItems([.remove], toSection: 1)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reload() {
        title = playlist?.name
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        let playlist = playlist
        var content: IconRowContentConfiguration
        switch row {
        case .name: content = IconRowContentConfiguration(symbol: "pencil", title: LiveTVCopy.playlistName, value: playlist?.name)
        case .address: content = IconRowContentConfiguration(symbol: "link", title: LiveTVCopy.playlistAddress, value: playlist?.address.host)
        case .guide: content = IconRowContentConfiguration(symbol: "calendar", title: LiveTVCopy.guideAddress, value: playlist?.guideAddresses.compactMap(\.host).joined(separator: ", "))
        case .agent: content = IconRowContentConfiguration(symbol: "person", title: LiveTVCopy.userAgent, value: playlist?.userAgent)
        case .link: content = IconRowContentConfiguration(symbol: "square.and.arrow.up", title: LiveTVCopy.sendToDevice, subtitle: LiveTVCopy.sendToDeviceFooter)
        case .remove:
            content = IconRowContentConfiguration(symbol: "trash", title: LiveTVCopy.removePlaylist)
            content.symbolColor = Theme.Color.destructive
        }
        content.isActionable = true
        cell.contentConfiguration = content
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard var playlist, let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .name:
            ask(LiveTVCopy.playlistName, text: playlist.name, keyboard: .default) { text in
                guard !text.isEmpty else { return }
                playlist.name = text
                LivePlaylistStore.save(playlist)
            }
        case .address:
            ask(LiveTVCopy.playlistAddress, text: playlist.address.absoluteString, keyboard: .URL) { [weak self] text in
                guard let url = LivePlaylist.address(from: text) else {
                    self?.notice(LiveTVCopy.invalidAddress)
                    return
                }
                playlist.address = url
                LivePlaylistStore.save(playlist)
            }
        case .guide:
            ask(LiveTVCopy.guideAddress, text: playlist.guideAddressesText, keyboard: .URL) { text in
                playlist.guideAddresses = LivePlaylist.addresses(from: text)
                LivePlaylistStore.save(playlist)
            }
        case .agent:
            ask(LiveTVCopy.userAgent, text: playlist.userAgent ?? "", keyboard: .default) { text in
                playlist.userAgent = text.isEmpty ? nil : text
                LivePlaylistStore.save(playlist)
            }
        case .link:
            guard let url = LiveTVLink.url(adding: playlist) else { return }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = collectionView.cellForItem(at: indexPath)
            present(share, animated: true)
        case .remove:
            let confirm = UIAlertController(title: LiveTVCopy.removePlaylistQuestion, message: LiveTVCopy.removePlaylistText, preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            confirm.addAction(UIAlertAction(title: LiveTVCopy.removePlaylist, style: .destructive) { [weak self] _ in
                LivePlaylistStore.remove(id: playlist.id)
                self?.navigationController?.popViewController(animated: true)
            })
            present(confirm, animated: true)
        }
    }

    private func ask(_ title: String, text: String, keyboard: UIKeyboardType, then apply: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.keyboardType = keyboard
            field.autocapitalizationType = keyboard == .URL ? .none : .words
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            apply((alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            self?.reload()
        })
        present(alert, animated: true)
    }

    private func notice(_ title: String) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
