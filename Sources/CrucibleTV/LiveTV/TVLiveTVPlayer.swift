import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import MidgarCore
import UIKit

/// The live channel player on the Apple TV: the system player with Channel Up, Channel Down, Previous Channel and a
/// Channels menu in its transport bar, the channels as an info panel swiped down to, the remote's next and previous track
/// changing channel, and the channel's name and airing in the info panel's title.
@MainActor
final class TVLiveTVPlayer: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private static var active: TVLiveTVPlayer?

    private let playback: LiveTVPlayback
    private let playerController = AVPlayerViewController()

    private init(channel: LiveChannel, guide: LiveTVGuide) {
        playback = LiveTVPlayback(channel: channel, guide: guide)
        super.init()
    }

    static func present(channel: LiveChannel, guide: LiveTVGuide, from host: UIViewController) {
        if let active, active.playerController.presentingViewController != nil {
            active.playback.tune(channel)
            return
        }
        active?.playback.stop()
        let player = TVLiveTVPlayer(channel: channel, guide: guide)
        active = player
        player.show(from: host)
    }

    private func show(from host: UIViewController) {
        playerController.player = playback.player
        playerController.delegate = self
        playerController.view.accessibilityIdentifier = "livetv.player"
        playerController.customInfoViewControllers = [TVLiveChannelsPanel(playback: playback)]
        playback.onChannel = { [weak self] _ in self?.refreshTransportBar() }
        playback.onFailure = { [weak self] message in self?.showFailure(message) }
        refreshTransportBar()
        host.present(playerController, animated: TVMotion.animationsEnabled) { [weak self] in self?.playback.start() }
    }

    private func refreshTransportBar() {
        var items: [UIMenuElement] = [
            UIAction(title: LiveTVCopy.channelDown, image: UIImage(systemName: "chevron.down")) { [weak self] _ in self?.playback.zap(by: -1) },
            UIAction(title: LiveTVCopy.channelUp, image: UIImage(systemName: "chevron.up")) { [weak self] _ in self?.playback.zap(by: 1) },
        ]
        if playback.previous != nil {
            items.append(UIAction(title: LiveTVCopy.previousChannel, image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.playback.previousChannel()
            })
        }
        playerController.transportBarCustomMenuItems = items
        if let program = playback.nowAiring {
            playerController.title = program.title
        }
        playerController.customInfoViewControllers.compactMap { $0 as? TVLiveChannelsPanel }.forEach { $0.reload() }
    }

    private func showFailure(_ message: String) {
        let alert = UIAlertController(title: LiveTVCopy.failedTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LiveTVCopy.tryAgain, style: .default) { [weak self] _ in
            guard let self else { return }
            self.playback.tune(self.playback.channel)
        })
        alert.addAction(UIAlertAction(title: LiveTVCopy.channelUp, style: .default) { [weak self] _ in self?.playback.zap(by: 1) })
        alert.addAction(UIAlertAction(title: String(localized: "Close"), style: .cancel) { [weak self] _ in
            self?.playerController.dismiss(animated: TVMotion.animationsEnabled)
            self?.stop()
        })
        playerController.present(alert, animated: TVMotion.animationsEnabled)
    }

    private func stop() {
        playback.stop()
        if Self.active === self { Self.active = nil }
    }

    func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool { true }

    func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        stop()
    }
}

/// The channels as a panel above the player, swiped down to: the channels around the one playing, favourites first, each
/// with what is on.
final class TVLiveChannelsPanel: UIViewController, UICollectionViewDelegate {
    private let playback: LiveTVPlayback
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())

    init(playback: LiveTVPlayback) {
        self.playback = playback
        super.init(nibName: nil, bundle: nil)
        title = LiveTVCopy.channels
        preferredContentSize = CGSize(width: 1920, height: 330)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let registration = UICollectionView.CellRegistration<LiveProgramCell, String> { [weak self] cell, _, id in
            guard let self, let channel = self.playback.guide?.channel(id: id) else { return }
            let program = self.playback.guide?.nowAndNext(id).now
            var configuration = LiveProgramContentConfiguration(title: channel.numberedTitle, detail: program?.title ?? LiveTVCopy.noGuide,
                                                                progress: program.map { $0.progress(at: Date()) })
            configuration.isPast = false
            cell.program = configuration
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        reload()
    }

    func reload() {
        guard dataSource != nil, let guide = playback.guide else { return }
        let current = playback.channel.id
        let favorites = LiveTVPreferences.favorites.filter { guide.channel(id: $0) != nil }
        let around = (-6...12).compactMap { guide.channel(from: current, offset: $0)?.id }
        var seen = Set<String>()
        let ids = (favorites + around).filter { seen.insert($0).inserted }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        snapshot.reconfigureItems(ids)
        dataSource.apply(snapshot, animatingDifferences: false)
        guide.loadPrograms(for: ids)
    }

    private func makeLayout() -> UICollectionViewLayout {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(420), heightDimension: .absolute(150)), subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Space.m
        section.contentInsets = NSDirectionalEdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)
        return UICollectionViewCompositionalLayout(section: section)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let channel = playback.guide?.channel(id: id) else { return }
        playback.tune(channel)
    }
}
