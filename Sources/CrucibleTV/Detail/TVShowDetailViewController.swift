import CrucibleCore
import MidgarCore
import UIKit

/// Show detail: the hero with Play or Continue for the up-next episode and a Mark Watched menu, a
/// row of season chips (selection is a press, never focus), the selected season's episodes, then
/// Cast & Crew and More Like This. The screen refreshes every time it appears.
@MainActor
final class TVShowDetailViewController: TVDetailViewController {
    private let showKey: String
    private let initialSeasonKey: String?
    private var model: ShowDetailModel?
    private lazy var seasonSlot = makeTaskSlot()
    private var loadingSeasonKey: String?
    private var episodesByID: [String: PlexMetadata] = [:]
    private var relatedByID: [String: PlexMetadata] = [:]
    private lazy var rating = RatingSaver(
        api: env.api,
        ratingKey: showKey,
        changed: { [weak self] in self?.rebuild() },
        reload: { [weak self] in self?.reload() },
        failed: { [weak self] in self?.presentAlert(title: String(localized: "Couldn\u{2019}t Update"), message: String(localized: "Your rating was not saved.")) }
    )

    init(env: TVAppEnvironment, ratingKey: String, initialSeasonKey: String?) {
        showKey = ratingKey
        self.initialSeasonKey = initialSeasonKey
        super.init(env: env)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func fetch() async {
        do {
            let loaded = try await ShowDetailLoader.load(
                api: env.api,
                showRatingKey: showKey,
                initialSeasonKey: initialSeasonKey,
                selectedSeasonKey: { [weak self] in self?.model?.selectedSeasonKey },
                onShow: { _ in }
            )
            guard let loaded else {
                if !hasContent { showUnavailable(DetailMessage.showUnavailable) }
                return
            }
            seasonSlot.cancel()
            loadingSeasonKey = nil
            model = loaded
            rating.loaded()
            rebuild()
        } catch {
            guard !Task.isCancelled else { return }
            MidgarLog.error("Show load failed ratingKey=\(showKey): \(error.localizedDescription)", category: .networking)
            if !hasContent { showFailure(title: String(localized: "Failed to load"), message: error.localizedDescription) }
        }
    }

    override func didSelect(_ item: Item) {
        switch item {
        case .season(let id):
            selectSeason(id)
        case .episode(let id):
            if let episode = episodesByID[id] { play(TVPlaybackRequest(item: episode)) }
        case .related(let id):
            if let related = relatedByID[id] { push(.related(related)) }
        case .person(let id):
            if let person = person(withID: id) { TVNavigation.push(TVScreens.filmography(env, person: person), from: self) }
        default:
            break
        }
    }

    private func person(withID id: String) -> PlexRole? {
        guard let index = Int(id.dropFirst("cast.".count)), let model else { return nil }
        let roles = MovieDetailModel(item: model.show).castAndCrew
        guard roles.indices.contains(index) else { return nil }
        return PersonFilmography.canOpen(roles[index]) ? roles[index] : nil
    }

    override func retryEpisodes() {
        guard let key = model?.selectedSeasonKey else { return }
        loadSeason(key)
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        if case .episode(let id)? = itemIdentifier(at: indexPath), let episode = episodesByID[id] {
            play(TVPlaybackRequest(item: episode))
            return true
        }
        guard model?.upNext != nil else { return false }
        playUpNext()
        return true
    }

    override func contextMenu(for item: Item) -> UIMenu? {
        guard case .episode(let id) = item, let model, let episode = episodesByID[id] else { return nil }
        let status = model.status(for: episode)
        var children: [UIMenuElement] = [
            UIAction(title: status.playTitle, image: UIImage(systemName: "play.fill")) { [weak self] _ in
                self?.play(TVPlaybackRequest(item: episode))
            },
        ]
        if status.canPlayFromBeginning {
            children.append(UIAction(title: String(localized: "Play from Beginning"), image: UIImage(systemName: "gobackward")) { [weak self] _ in
                self?.play(TVPlaybackRequest(item: episode, resumeSeconds: 0))
            })
        }
        children.append(UIMenu(title: String(localized: "Watched", comment: "Watch state of an item or season"), image: UIImage(systemName: "eye"), children: [
            UIAction(
                title: String(localized: "Mark Watched"),
                image: UIImage(systemName: "checkmark.circle"),
                state: episode.isWatched ? .on : .off
            ) { [weak self] _ in
                self?.markWatched(true, ratingKey: episode.id)
            },
            UIAction(
                title: String(localized: "Mark Unwatched"),
                image: UIImage(systemName: "eye.slash"),
                state: episode.isWatched ? .off : .on
            ) { [weak self] _ in
                self?.markWatched(false, ratingKey: episode.id)
            },
        ]))
        children.append(UIAction(title: String(localized: "Episode Details"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.push(.item(ratingKey: episode.id, mediaType: "episode", showRatingKey: self?.showKey, seasonRatingKey: model.selectedSeasonKey))
        })
        return UIMenu(children: children)
    }

    private func rebuild() {
        guard let model else { return }
        let episodes = model.episodes
        let episodeCards = episodes.map { TVDetailMapping.episode($0, status: model.status(for: $0)) }
        episodesByID = Dictionary(zip(episodeCards.map(\.id), episodes), uniquingKeysWith: { first, _ in first })
        let related = model.related
        let relatedCards = TVDetailMapping.related(related)
        relatedByID = Dictionary(zip(relatedCards.map(\.id), related), uniquingKeysWith: { first, _ in first })
        let episodesState: TVDetailContent.EpisodesState = model.episodesFailed ? .failed : (loadingSeasonKey == nil ? .loaded : .loading)

        present(TVDetailContent(
            artwork: model.heroArtwork,
            header: TVDetailMapping.heroInfo(model.heroInfo, progress: nil),
            synopsis: model.hasSummary ? model.show.summary : nil,
            synopsisTitle: model.show.title,
            actions: actions(for: model),
            seasons: model.seasonChips.map {
                TVChipItem(id: $0.id, title: [$0.title, $0.watchedText].compactMap { $0 }.joined(separator: "  ·  "), isSelected: $0.isSelected)
            },
            episodesHeader: TVSectionHeader(title: model.selectedSeasonTitle, secondaryText: episodesState == .loaded ? Self.episodeCount(episodes.count) : nil),
            episodes: episodeCards,
            showsEpisodes: model.selectedSeason != nil,
            episodesState: episodesState,
            cast: TVDetailMapping.people(MovieDetailModel(item: model.show).castAndCrew),
            related: relatedCards
        ))
    }

    private func actions(for model: ShowDetailModel) -> [TVDetailAction] {
        var actions = [
            TVDetailAction(
                kind: .primary,
                title: model.primaryTitle,
                symbol: "play.fill",
                appearance: .primary,
                isEnabled: model.isPrimaryEnabled,
                accessibilityLabel: model.primaryAccessibilityLabel,
                handler: { [weak self] in self?.playUpNext() }
            ),
        ]
        if let menu = watchedMenu(for: model) {
            actions.append(TVDetailAction(
                kind: .watched,
                title: model.isWatched ? String(localized: "Watched", comment: "Watch state of an item or season") : WatchedService.title(isWatched: false),
                menu: menu,
                accessibilityLabel: model.watchedAccessibilityLabel
            ))
        }
        let current = rating.shown(served: model.userRating)
        actions.append(TVDetailAction(
            kind: .rate,
            title: UserRatingCopy.actionTitle(for: current),
            symbol: current == nil ? "star" : "star.fill",
            accessibilityLabel: UserRatingCopy.accessibilityLabel(for: current),
            handler: { [weak self] in
                guard let self else { return }
                presentRating(title: model.show.title, rating: current) { self.rating.save($0) }
            }
        ))
        let show = model.show
        actions.append(TVDetailAction(
            kind: .playlist,
            title: PlaylistFormat.addToPlaylist,
            symbol: "text.badge.plus",
            handler: { [weak self] in
                guard let self else { return }
                TVPlaylistPicker.present(adding: [show], env: env, from: self)
            }
        ))
        return actions
    }

    private func watchedMenu(for model: ShowDetailModel) -> UIMenu? {
        let options = model.watchedOptions
        guard !options.show.isEmpty || !options.season.isEmpty else { return nil }
        let groups = [options.show, options.season].filter { !$0.isEmpty }.map { group in
            UIMenu(title: "", options: .displayInline, children: group.map(watchedAction))
        }
        return UIMenu(title: "", children: groups)
    }

    private func watchedAction(_ option: ShowDetailModel.WatchedOption) -> UIAction {
        UIAction(title: option.title, image: UIImage(systemName: option.watched ? "checkmark.circle" : "eye.slash")) { [weak self] _ in
            self?.markWatched(option.watched, ratingKey: option.ratingKey)
        }
    }

    private func playUpNext() {
        guard let episode = model?.upNext?.episode else { return }
        play(TVPlaybackRequest(item: episode))
    }

    /// Selecting the season already shown does nothing unless its fetch failed, in which case it is the retry.
    private func selectSeason(_ key: String) {
        guard let current = model else { return }
        guard current.selectedSeasonKey != key || current.episodesFailed else { return }
        loadSeason(key)
    }

    /// Shows `key` with a loading shelf at once and fills it when its episodes arrive. A response for a
    /// season that is no longer selected is dropped, so a slow earlier pick cannot replace a later one.
    private func loadSeason(_ key: String) {
        guard let current = model else { return }
        model = current.loadingSeason(key)
        loadingSeasonKey = key
        rebuild()
        seasonSlot.run { [weak self] in
            guard let self else { return }
            let result = await ShowDetailLoader.loadSeason(key, api: env.api)
            guard model?.selectedSeasonKey == key, loadingSeasonKey == key else { return }
            switch result {
            case .loaded(let episodes): model = model?.replacingEpisodes(episodes)
            case .failed: model = model?.failingEpisodes()
            case .cancelled: return
            }
            loadingSeasonKey = nil
            rebuild()
        }
    }

    private static func episodeCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 episode") : String(localized: "\(count) episodes")
    }
}
