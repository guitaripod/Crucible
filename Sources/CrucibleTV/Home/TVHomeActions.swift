import CrucibleCore
import CrucibleDesign
import MidgarCore
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
        TVNavigation.push(destination, from: screen)
    }

    func open(_ target: SurpriseMe.Target, from screen: UIViewController) {
        let destination: UIViewController
        switch target {
        case .movie(let ratingKey): destination = TVScreens.movieDetail(env, ratingKey: ratingKey, mediaType: "movie")
        case .show(let ratingKey): destination = TVScreens.showDetail(env, ratingKey: ratingKey, initialSeasonKey: nil)
        }
        TVNavigation.push(destination, from: screen)
    }

    func openStatistics(from screen: UIViewController) {
        TVNavigation.push(TVScreens.statistics(env), from: screen)
    }

    /// Play/Resume, Play from Beginning, View Details, Go to Show, Mark (Un)Watched and Remove from Continue Watching;
    /// entries that do not apply are omitted.
    func menu(for media: PlexMetadata, in bucket: HomeBucket? = nil, from screen: UIViewController) -> UIMenu {
        var actions = [UIMenuElement]()
        if HomeMediaRules.isPlayable(media) {
            actions.append(UIAction(title: HomeMediaRules.playTitle(for: media), image: UIImage(systemName: "play.fill")) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                play(media, from: screen)
            })
            if HomeMediaRules.isResuming(media) {
                actions.append(UIAction(title: String(localized: "Play from Beginning"), image: UIImage(systemName: "gobackward")) { [weak self, weak screen] _ in
                    guard let self, let screen else { return }
                    play(media, restarting: true, from: screen)
                })
            }
        }
        actions.append(UIAction(title: String(localized: "View Details"), image: UIImage(systemName: "info.circle")) { [weak self, weak screen] _ in
            guard let self, let screen else { return }
            openDetail(media, from: screen)
        })
        if let showKey = HomeMediaRules.showRatingKey(for: media) {
            actions.append(UIAction(title: String(localized: "Go to Show"), image: UIImage(systemName: "tv")) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                TVNavigation.push(TVScreens.showDetail(env, ratingKey: showKey, initialSeasonKey: nil), from: screen)
            })
        }
        actions.append(watchedAction(for: media))
        if let bucket, ContinueWatchingRemoval.applies(to: media, in: bucket) {
            actions.append(removalAction(for: media, from: screen))
        }
        if media.isPlaylistable {
            actions.append(UIAction(title: PlaylistFormat.addToPlaylist, image: UIImage(systemName: "text.badge.plus")) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                TVPlaylistPicker.present(adding: [media], env: env, from: screen)
            })
        }
        if let manage = manageMenu(for: media, from: screen) { actions.append(manage) }
        return UIMenu(children: actions)
    }

    /// The owner's Manage menu for a title; nothing for anyone else.
    private func manageMenu(for media: PlexMetadata, from screen: UIViewController) -> UIMenu? {
        TVManageMenus.itemMenu(for: media, env: env, host: screen) { [weak self] in self?.onChange() }
    }

    private func removalAction(for media: PlexMetadata, from screen: UIViewController) -> UIAction {
        let api = env.api
        return UIAction(title: ContinueWatchingRemoval.title, image: UIImage(systemName: ContinueWatchingRemoval.symbol)) { [weak self, weak screen] _ in
            Task { @MainActor in
                do {
                    try await ContinueWatchingRemoval.remove(ratingKey: media.id, api: api)
                } catch {
                    screen?.presentAlert(title: ContinueWatchingRemoval.failureTitle, message: ContinueWatchingRemoval.failureMessage)
                }
                self?.onChange()
            }
        }
    }

    // MARK: - Rate What You Watched

    /// The half-star panel for a title the viewer finished. `picked` drops the card at once, and brings it back with false
    /// when the server refused the rating.
    func rate(_ ask: RatingAsk, from screen: UIViewController, picked: @escaping @MainActor (Bool) -> Void) {
        let api = env.api
        let panel = TVRatingViewController(title: RatingAskCopy.question(for: ask), rating: nil) { [weak screen] rating in
            guard let rating else { return }
            picked(true)
            Task { @MainActor in
                do {
                    try await RatingService.setRating(rating, ratingKey: ask.ratingKey, api: api)
                } catch {
                    picked(false)
                    screen?.presentAlert(title: String(localized: "Couldn’t Save Rating", comment: "Alert title when the server refused a star rating"))
                }
            }
        }
        screen.present(panel, animated: TVMotion.animationsEnabled)
    }

    func menu(for ask: RatingAsk, from screen: UIViewController, picked: @escaping @MainActor (Bool) -> Void) -> UIMenu {
        UIMenu(children: [
            UIAction(title: UserRatingCopy.rate, image: UIImage(systemName: "star")) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                rate(ask, from: screen, picked: picked)
            },
            UIAction(title: String(localized: "View Details"), image: UIImage(systemName: "info.circle")) { [weak self, weak screen] _ in
                guard let self, let screen else { return }
                openDetail(ask, from: screen)
            },
            UIAction(title: RatingAskCopy.notNow, image: UIImage(systemName: "xmark.circle")) { _ in
                FinishedTitlesLedger.shared.dismiss(ask.ratingKey)
            },
        ])
    }

    func openDetail(_ ask: RatingAsk, from screen: UIViewController) {
        let destination = ask.isShow
            ? TVScreens.showDetail(env, ratingKey: ask.ratingKey, initialSeasonKey: nil)
            : TVScreens.movieDetail(env, ratingKey: ask.ratingKey, mediaType: ask.mediaType)
        TVNavigation.push(destination, from: screen)
    }

    private func watchedAction(for media: PlexMetadata) -> UIAction {
        let toggle = HomeMediaRules.watchedToggle(for: media)
        let api = env.api
        return UIAction(title: toggle.title, image: UIImage(systemName: toggle.isWatched ? "eye.slash" : "eye")) { [weak self] _ in
            Task { @MainActor in
                do {
                    try await toggle.perform(using: api)
                } catch {
                    MidgarLog.error("Home mark watched failed ratingKey=\(media.id): \(error.localizedDescription)", category: .networking)
                }
                self?.onChange()
            }
        }
    }
}
