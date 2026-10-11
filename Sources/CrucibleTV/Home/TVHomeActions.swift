import CrucibleCore
import CrucibleDesign
import UIKit

/// What a Home card can do, shared by the Home screen and its See All grids: open its detail, play
/// it, and build the long-press menu. `onChange` runs after an action changed server state.
@MainActor
final class TVHomeActions {
    private let env: TVAppEnvironment
    private let onChange: @MainActor () -> Void

    init(env: TVAppEnvironment, onChange: @escaping @MainActor () -> Void) {
        self.env = env
        self.onChange = onChange
    }

    func select(_ media: PlexMetadata, in bucket: HomeBucket, from screen: UIViewController) {
        switch HomeTapPolicy.action(for: media, in: bucket) {
        case .play: play(media, from: screen)
        case .openDetail: openDetail(media, from: screen)
        }
    }

    func playPause(_ media: PlexMetadata, from screen: UIViewController) {
        guard HomeTapPolicy.playPauseAction(for: media) == .play else { return }
        play(media, from: screen)
    }

    func play(_ media: PlexMetadata, restarting: Bool = false, from screen: UIViewController) {
        guard HomeTapPolicy.playOrDetail(for: media) == .play else {
            openDetail(media, from: screen)
            return
        }
        let request = restarting ? TVPlaybackRequest(item: media, resumeSeconds: 0) : TVPlaybackRequest(item: media)
        TVScreens.play(env, request: request, from: screen)
    }

    func openDetail(_ media: PlexMetadata, from screen: UIViewController) {
        let destination: UIViewController
        switch HomeMediaRules.detailRoute(for: media) {
        case .show(let ratingKey, let initialSeasonKey):
            destination = TVScreens.showDetail(env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .media(let ratingKey, let mediaType, _, _):
            destination = TVScreens.movieDetail(env, ratingKey: ratingKey, mediaType: mediaType)
        }
        screen.navigationController?.pushViewController(destination, animated: true)
    }

    func open(_ target: SurpriseMe.Target, from screen: UIViewController) {
        let destination: UIViewController
        switch target {
        case .movie(let ratingKey): destination = TVScreens.movieDetail(env, ratingKey: ratingKey, mediaType: "movie")
        case .show(let ratingKey): destination = TVScreens.showDetail(env, ratingKey: ratingKey, initialSeasonKey: nil)
        }
        screen.navigationController?.pushViewController(destination, animated: true)
    }

    func openStatistics(from screen: UIViewController) {
        screen.navigationController?.pushViewController(TVScreens.statistics(env), animated: true)
    }

    /// Play/Resume, Play from Beginning, View Details, Go to Show and Mark (Un)Watched; entries that do not apply are omitted.
    func menu(for media: PlexMetadata, from screen: UIViewController) -> UIMenu {
        var actions = [UIMenuElement]()
        if HomeMediaRules.isPlayable(media) {
            actions.append(UIAction(title: HomeMediaRules.playTitle(for: media), image: UIImage(systemName: "play.fill")) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                play(media, from: screen)
            })
            if HomeMediaRules.isResuming(media) {
                actions.append(UIAction(title: "Play from Beginning", image: UIImage(systemName: "gobackward")) { [weak self, weak screen] _ in
                    guard let self, let screen else { return }
                    play(media, restarting: true, from: screen)
                })
            }
        }
        actions.append(UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { [weak self, weak screen] _ in
            guard let self, let screen else { return }
            openDetail(media, from: screen)
        })
        if let showKey = HomeMediaRules.showRatingKey(for: media) {
            actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                let show = TVScreens.showDetail(env, ratingKey: showKey, initialSeasonKey: nil)
                screen.navigationController?.pushViewController(show, animated: true)
            })
        }
        actions.append(watchedAction(for: media))
        return UIMenu(children: actions)
    }

    private func watchedAction(for media: PlexMetadata) -> UIAction {
        let toggle = HomeMediaRules.watchedToggle(for: media)
        let api = env.api
        return UIAction(title: toggle.title, image: UIImage(systemName: toggle.isWatched ? "eye.slash" : "eye")) { [weak self] _ in
            Task { @MainActor in
                do {
                    try await toggle.perform(using: api)
                } catch {
                    AppLogger.error("Home mark watched failed ratingKey=\(media.id): \(error.localizedDescription)", .networking)
                }
                self?.onChange()
            }
        }
    }
}
