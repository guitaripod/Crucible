import CrucibleCore
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
            rebuild()
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.error("Show load failed ratingKey=\(showKey): \(error.localizedDescription)", .networking)
            if !hasContent { showFailure(title: "Failed to load", message: error.localizedDescription) }
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
        default:
            break
        }
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
        var children = [
            UIAction(title: status.playTitle, image: UIImage(systemName: "play.fill")) { [weak self] _ in
                self?.play(TVPlaybackRequest(item: episode))
            },
        ]
        if status.canPlayFromBeginning {
            children.append(UIAction(title: "Play from Beginning", image: UIImage(systemName: "gobackward")) { [weak self] _ in
                self?.play(TVPlaybackRequest(item: episode, resumeSeconds: 0))
            })
        }
        children.append(UIAction(
            title: status.watchedToggleTitle,
            image: UIImage(systemName: episode.isWatched ? "eye.slash" : "eye")
        ) { [weak self] _ in
            self?.markWatched(!episode.isWatched, ratingKey: episode.id)
        })
        children.append(UIAction(title: "Episode Details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
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
                title: model.isWatched ? "Watched" : "Mark Watched",
                menu: menu,
                accessibilityLabel: model.watchedAccessibilityLabel
            ))
        }
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
        count == 1 ? "1 episode" : "\(count) episodes"
    }
}
