import CrucibleCore
import UIKit

/// Live TV search's results, for a `UISearchController` on the iPhone, the iPad and the Apple TV: channels by name or
/// number, airings on now with how long is left, and airings later with when they start, as a list. The first search asks
/// for every channel's airings, and the results fill in as those arrive. Choosing a channel or what is on plays it; an
/// airing to come opens its actions.
package final class LiveSearchResultsController: UIViewController, UISearchResultsUpdating, UICollectionViewDelegate {
    private enum Section: Hashable {
        case channels, onNow, later, note
    }

    private enum Item: Hashable {
        case channel(String)
        case airing(channel: String, program: String)
        case note(String)
    }

    private let guide: LiveTVGuide
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var query = ""
    private var pending: Task<Void, Never>?
    private var askedForEveryGuide = false
    private var logos: [URL: UIImage] = [:]
    private var logoTasks: [URL: Task<Void, Never>] = [:]

    /// Plays a channel.
    package var onPlay: ((LiveChannel) -> Void)?
    /// Opens the actions of an airing to come, from the row that shows it.
    package var onAiring: ((LiveChannel, LiveProgram, UIView?) -> Void)?

    package init(guide: LiveTVGuide) {
        self.guide = guide
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pending?.cancel()
        logoTasks.values.forEach { $0.cancel() }
    }

    package override func viewDidLoad() {
        super.viewDidLoad()
        #if os(tvOS)
        var list = UICollectionLayoutListConfiguration(appearance: .grouped)
        #else
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        #endif
        list.headerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "livetv.search.results"
        #if os(iOS)
        collectionView.keyboardDismissMode = .onDrag
        #endif
        view.addSubview(collectionView)
        configureDataSource()
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self.flatMap { $0.dataSource.sectionIdentifier(for: indexPath.section) }.map(Self.title(of:)) ?? nil
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func title(of section: Section) -> String? {
        switch section {
        case .channels: LiveTVCopy.channels
        case .onNow: LiveTVCopy.nowPlaying
        case .later: LiveTVCopy.searchLater
        case .note: nil
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        let now = Date()
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = Theme.Color.labelSecondary
        content.imageProperties.maximumSize = CGSize(width: 64, height: 40)
        content.imageProperties.reservedLayoutSize = CGSize(width: 64, height: 40)
        content.imageProperties.cornerRadius = Theme.Radius.xs
        var trailing: String?
        var logo: URL?
        switch item {
        case .channel(let id):
            guard let channel = guide.channel(id: id) else { break }
            let label = LiveChannelLabel(channel)
            let airing = guide.nowAndNext(id, at: now).now
            content.text = [label.number, label.name].compactMap { $0 }.joined(separator: "  ")
            content.secondaryText = airing.map { "\(LiveTVCopy.nowPlaying): \($0.title)" } ?? label.tags.joined(separator: " · ")
            trailing = airing.map { LiveGuideMath.remaining($0, at: now) }
            logo = channel.logo
        case .airing(let channelID, let programID):
            guard let channel = guide.channel(id: channelID), let program = guide.programs(of: channelID).first(where: { $0.id == programID }) else { break }
            let label = LiveChannelLabel(channel)
            content.text = program.title
            content.secondaryText = [[label.number, label.name].compactMap { $0 }.joined(separator: " "), program.episodeCode, program.episodeTitle]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            trailing = program.isOn(at: now) ? LiveGuideMath.remaining(program, at: now) : LiveTVCopy.startsAt(program.start, now: now)
            logo = channel.logo
        case .note(let text):
            content = UIListContentConfiguration.cell()
            content.text = text
            content.textProperties.color = Theme.Color.labelSecondary
        }
        if let logo {
            content.image = logos[logo] ?? UIImage(systemName: "tv")
            content.imageProperties.tintColor = Theme.Color.labelSecondary
            loadLogo(logo)
        }
        cell.contentConfiguration = content
        cell.accessories = trailing.map { [.label(text: $0, options: .init(isHidden: false, reservedLayoutWidth: .actual, tintColor: Theme.Color.labelSecondary))] } ?? []
    }

    private func loadLogo(_ url: URL) {
        guard logos[url] == nil, logoTasks[url] == nil else { return }
        logoTasks[url] = Task { [weak self] in
            let image = await RemoteImageLoader.shared.image(at: url)
            guard let self, !Task.isCancelled else { return }
            self.logoTasks[url] = nil
            guard let image else { return }
            self.logos[url] = image
            var snapshot = self.dataSource.snapshot()
            let touched = snapshot.itemIdentifiers.filter { item in
                switch item {
                case .channel(let id), .airing(let id, _): self.guide.channel(id: id)?.logo == url
                case .note: false
                }
            }
            guard !touched.isEmpty else { return }
            snapshot.reconfigureItems(touched)
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    package func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        refresh(after: .milliseconds(150))
    }

    /// Searches again a moment from now, as when more channels' airings arrive.
    package func refresh(after delay: Duration = .milliseconds(400)) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    private func render() {
        guard dataSource != nil else { return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        defer { dataSource.apply(snapshot, animatingDifferences: false) }
        guard !trimmed.isEmpty else { return }
        if !askedForEveryGuide {
            askedForEveryGuide = true
            guide.loadAllPrograms()
        }
        let found = guide.search(trimmed)
        if !found.channels.isEmpty {
            snapshot.appendSections([.channels])
            snapshot.appendItems(found.channels.prefix(12).map { .channel($0.id) }, toSection: .channels)
        }
        if !found.onNow.isEmpty {
            snapshot.appendSections([.onNow])
            snapshot.appendItems(found.onNow.prefix(20).map { .airing(channel: $0.channel.id, program: $0.program.id) }, toSection: .onNow)
        }
        if !found.later.isEmpty {
            snapshot.appendSections([.later])
            snapshot.appendItems(found.later.prefix(30).map { .airing(channel: $0.channel.id, program: $0.program.id) }, toSection: .later)
        }
        let stillLoading = guide.channels.contains { guide.programs[$0.id] == nil }
        if stillLoading || found.isEmpty {
            snapshot.appendSections([.note])
            snapshot.appendItems([.note(stillLoading ? LiveTVCopy.searchStillLoading : LiveTVCopy.searchNothing)], toSection: .note)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
    }

    package func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .note = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    #if os(tvOS)
    package func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if case .note = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }
    #endif

    package func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .channel(let id):
            if let channel = guide.channel(id: id) { onPlay?(channel) }
        case .airing(let channelID, let programID):
            guard let channel = guide.channel(id: channelID), let program = guide.programs(of: channelID).first(where: { $0.id == programID }) else { return }
            if program.isOn(at: Date()) {
                onPlay?(channel)
            } else {
                onAiring?(channel, program, collectionView.cellForItem(at: indexPath))
            }
        case .note, nil:
            break
        }
    }
}
