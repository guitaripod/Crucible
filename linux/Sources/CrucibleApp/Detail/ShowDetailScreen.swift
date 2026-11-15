import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A show page (`TVShowDetailViewController`): Play Up Next or Continue, the Watched menu for the show and its season,
/// Rate and Add to Playlist; the season chips with what is watched of each, the season's episodes (selecting one plays
/// it, a right click offers Play, Play from Beginning, Watched and Episode Details), Cast & Crew and More Like This.
@MainActor
final class ShowDetailScreen: DetailScreen {
    private let showKey: String
    private let initialSeasonKey: String?
    private var model: ShowDetailModel?
    private var loadingSeasonKey: String?
    private var seasonTask: Task<Void, Never>?
    private let seasons = ChipRowView()
    private let episodes = ShelfView(header: nil, style: .episode)
    private let episodesLoading = SkeletonShelfView(style: .episode)
    private let episodesFailed = SeasonMessageView()
    private let cast = ShelfView(header: SectionHeader(title: String(localized: "Cast & Crew")), style: .person)
    private let related = ShelfView(header: SectionHeader(title: String(localized: "More Like This")), style: .poster)
    private lazy var rating = RatingSaver(
        api: api,
        ratingKey: showKey,
        changed: { [weak self] in self?.rebuild() },
        reload: { [weak self] in self?.reload() },
        failed: { [weak self] in self?.alert(String(localized: "Couldn’t Update"), message: String(localized: "Your rating was not saved.")) }
    )

    init(api: APIClient, ratingKey: String, initialSeasonKey: String?, placeholder: PlexMetadata?) {
        showKey = ratingKey
        self.initialSeasonKey = initialSeasonKey
        super.init(api: api, placeholder: placeholder)
        seasons.onSelect = { [weak self] chip in self?.selectSeason(chip.id) }
        episodes.onActivate = { [weak self] card in
            guard let self, let episode = self.episode(card.id) else { return }
            self.rootView?.play(item: episode, api: self.api)
        }
        episodes.onContextMenu = { [weak self] card, point in
            guard let self, let episode = self.episode(card.id) else { return }
            self.presentEpisodeMenu(episode, at: point, from: self.episodes.card(for: card.id))
        }
        episodesFailed.onRetry = { [weak self] in
            guard let key = self?.model?.selectedSeasonKey else { return }
            self?.loadSeason(key)
        }
        cast.onActivate = { [weak self] card in
            guard let self, let person = self.person(card.id) else { return }
            self.openPerson(person)
        }
        related.onActivate = { [weak self] card in
            guard let self, let item = self.model?.related.first(where: { "related.\($0.id)" == card.id }) else { return }
            self.push(.related(item))
        }
        related.onContextMenu = { [weak self] card, point in
            guard let self, let item = self.model?.related.first(where: { "related.\($0.id)" == card.id }) else { return }
            ItemActions.present(for: item, api: self.api, at: point, in: self) { [weak self] in self?.reload() }
        }
    }

    override func fetch() async {
        do {
            let model = try await ShowDetailLoader.load(api: api, showRatingKey: showKey, initialSeasonKey: initialSeasonKey,
                                                        selectedSeasonKey: { [weak self] in self?.model?.selectedSeasonKey },
                                                        onShow: { [weak self] show in self?.showArrived(show) })
            guard !Task.isCancelled else { return }
            guard let model else {
                if !hasContent { showUnavailable(DetailMessage.showUnavailable) }
                return
            }
            self.model = model
            loadingSeasonKey = nil
            rating.loaded()
            rebuild()
        } catch {
            guard !Task.isCancelled else { return }
            MidgarLog.error("Show load failed ratingKey=\(showKey): \(error)", category: .networking)
            if !hasContent { showFailure(title: String(localized: "Failed to load"), message: ConnectionError.message(for: error)) }
        }
    }

    /// The show itself arrived before its seasons: its title and artwork go up at once.
    private func showArrived(_ show: PlexMetadata) {
        guard !hasContent else { return }
        hero.configure(HeroInfo(title: show.title, titleStyle: .title1), animated: true)
        if let art = show.art { backdrop.show(.path(art, .backdrop), immediate: true) }
    }

    private func rebuild() {
        guard let model else { return }
        let rows = model.episodeRows(showingSkipped: true)
        var cards: [CardItem] = []
        for row in rows {
            guard case .episode(let episode) = row else { continue }
            cards.append(card(for: episode, status: model.status(for: episode)))
        }
        seasons.setChips(model.seasonChips.map {
            ChipRowView.Chip(id: $0.id, title: [$0.title, $0.watchedText].compactMap { $0 }.joined(separator: "  ·  "), isSelected: $0.isSelected,
                             isDimmed: $0.isMissing)
        })
        let loading = loadingSeasonKey != nil
        let count = cards.count
        episodes.header = SectionHeader(title: model.selectedSeasonTitle,
                                        secondaryText: loading || model.episodesFailed ? nil : Self.episodeCount(count))
        episodes.setItems(cards)
        let roles = MovieDetailModel(item: model.show).castAndCrew
        cast.setItems(roles.enumerated().map { DetailMapping.person($1, index: $0) })
        related.setItems(DetailMapping.related(model.related))
        var sections: [View] = []
        if !model.seasonChips.isEmpty { sections.append(seasons) }
        if model.selectedSeason != nil {
            if loading {
                sections.append(episodesLoading)
            } else if model.episodesFailed {
                episodesFailed.message = String(localized: "Couldn’t load this season.")
                episodesFailed.showsRetry = true
                sections.append(episodesFailed)
            } else if cards.isEmpty {
                episodesFailed.message = String(localized: "No episodes in this season")
                episodesFailed.showsRetry = false
                sections.append(episodesFailed)
            } else {
                sections.append(episodes)
            }
        }
        if !roles.isEmpty { sections.append(cast) }
        if !model.related.isEmpty { sections.append(related) }
        present(hero: DetailMapping.hero(model.heroInfo, progress: nil), artwork: model.heroArtwork,
                synopsis: model.hasSummary ? model.show.summary : nil, synopsisTitle: model.show.title, actions: actions(for: model), sections: sections)
    }

    /// An episode card as the Apple TV draws it: number and title, runtime or air date, an eyebrow for Continue and Up Next,
    /// progress, and watched episodes dimmed.
    private func card(for episode: PlexMetadata, status: EpisodeStatus) -> CardItem {
        let number = status.episodeNumber.map { "\($0)  ·  " } ?? ""
        let eyebrow: String?
        switch status.marker {
        case .inProgress: eyebrow = String(localized: "Continue", comment: "Action title that resumes a partly watched item")
        case .upNext: eyebrow = String(localized: "Up Next")
        default: eyebrow = nil
        }
        return CardItem(id: "episode.\(episode.id)", artwork: episode.thumb.map { .path($0, .backdrop) }, title: number + status.title,
                        subtitle: status.metaText.isEmpty ? nil : status.metaText, eyebrow: eyebrow, progress: status.progress,
                        isWatched: status.isWatched, isDimmed: status.isWatched || status.isSkipped, placeholderSymbol: "tv")
    }

    private func actions(for model: ShowDetailModel) -> [DetailAction] {
        var list = [DetailAction(id: "primary", title: model.primaryTitle, symbol: "play.fill", isPrimary: true, isEnabled: model.isPrimaryEnabled,
                                 behaviour: .run { [weak self] in self?.playUpNext() })]
        let options = model.watchedOptions
        let watchedItems = (options.show + options.season).enumerated().map { index, option in
            MenuView.Item(id: "\(index)", title: option.title, symbol: option.watched ? "checkmark.circle" : "eye.slash")
        }
        if !watchedItems.isEmpty {
            let all = options.show + options.season
            let title = model.isWatched ? String(localized: "Watched", comment: "Watch state of an item or season") : WatchedService.title(isWatched: false)
            list.append(DetailAction(id: "watched", title: title, symbol: model.isWatched ? "checkmark.circle.fill" : "checkmark.circle",
                                     behaviour: .menu(title: nil, items: watchedItems) { [weak self] chosen in
                                         guard let index = Int(chosen.id), all.indices.contains(index) else { return }
                                         self?.markWatched(all[index].watched, ratingKey: all[index].ratingKey)
                                     }))
        }
        let current = rating.shown(served: model.userRating)
        list.append(DetailAction(id: "rate", title: UserRatingCopy.actionTitle(for: current), symbol: current == nil ? "star" : "star.fill",
                                 behaviour: .run { [weak self] in self?.presentRating(title: model.show.title, current: current) }))
        let show = model.show
        list.append(DetailAction(id: "playlist", title: PlaylistFormat.addToPlaylist, symbol: "text.badge.plus", behaviour: .run { [weak self] in
            guard let self, let window = self.window else { return }
            PlaylistPicker.present(adding: [show], api: self.api, in: window)
        }))
        if let manage = manageAction(for: show) { list.append(manage) }
        return list
    }

    private func playUpNext() {
        guard let episode = model?.upNext?.episode else { return }
        rootView?.play(item: episode, api: api)
    }

    private func episode(_ cardID: String) -> PlexMetadata? {
        model?.episodes.first { "episode.\($0.id)" == cardID }
    }

    private func person(_ id: String) -> PlexRole? {
        guard let index = Int(id.dropFirst("cast.".count)), let model else { return nil }
        let roles = MovieDetailModel(item: model.show).castAndCrew
        guard roles.indices.contains(index) else { return nil }
        return PersonFilmography.canOpen(roles[index]) ? roles[index] : nil
    }

    /// An episode's menu on right click or the Menu key: play or resume it, play it from the beginning, mark it watched or
    /// unwatched, or open its own page.
    private func presentEpisodeMenu(_ episode: PlexMetadata, at point: Point?, from card: View?) {
        guard let window, let model else { return }
        let status = model.status(for: episode)
        var items = [MenuView.Item(id: "play", title: status.playTitle, symbol: "play.fill")]
        if status.canPlayFromBeginning {
            items.append(MenuView.Item(id: "restart", title: String(localized: "Play from Beginning"), symbol: "gobackward"))
        }
        items.append(MenuView.Item(id: "watched", title: String(localized: "Mark Watched"), symbol: "checkmark.circle", isChecked: episode.isWatched))
        items.append(MenuView.Item(id: "unwatched", title: String(localized: "Mark Unwatched"), symbol: "eye.slash", isChecked: !episode.isWatched))
        items.append(MenuView.Item(id: "details", title: String(localized: "Episode Details"), symbol: "info.circle"))
        let frame = card?.frameInWindow ?? frameInWindow
        let anchor = Rect(x: point?.x ?? frame.minX, y: point?.y ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: episode.title, items: items, anchor: anchor)
        let seasonKey = model.selectedSeasonKey
        menu.onSelect = { [weak self] chosen in
            guard let self else { return }
            switch chosen.id {
            case "play": self.rootView?.play(item: episode, api: self.api)
            case "restart": self.rootView?.play(item: episode, api: self.api, from: 0)
            case "watched": self.markWatched(true, ratingKey: episode.id)
            case "unwatched": self.markWatched(false, ratingKey: episode.id)
            case "details":
                self.push(.item(ratingKey: episode.id, mediaType: "episode", showRatingKey: self.showKey, seasonRatingKey: seasonKey))
            default: break
            }
        }
        menu.present(in: window)
    }

    private func markWatched(_ watched: Bool, ratingKey: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(watched, ratingKey: ratingKey, api: self.api)
                self.reload()
            } catch {
                MidgarLog.error("Watched toggle failed: \(error)", category: .networking)
                self.alert(String(localized: "Couldn’t Update"), message: ConnectionError.message(for: error))
            }
        }
    }

    private func presentRating(title: String, current: UserRating?) {
        guard let window else { return }
        let panel = RatingPanelView(title: title, halfStars: current?.halfStars, clearTitle: String(localized: "Clear Rating"))
        panel.onCommit = { [weak self] halfStars in self?.rating.save(halfStars.flatMap(UserRating.init(halfStars:))) }
        panel.present(in: window)
    }

    /// Selecting the season already shown does nothing unless its fetch failed, in which case it is the retry.
    private func selectSeason(_ key: String) {
        guard let current = model else { return }
        guard current.selectedSeasonKey != key || current.episodesFailed else { return }
        loadSeason(key)
    }

    /// Shows `key` loading at once and fills it when its episodes arrive; a response for a season no longer selected is
    /// dropped, so a slow earlier pick cannot replace a later one.
    private func loadSeason(_ key: String) {
        guard let current = model else { return }
        model = current.loadingSeason(key)
        loadingSeasonKey = key
        rebuild()
        seasonTask?.cancel()
        seasonTask = Task { [weak self] in
            guard let self else { return }
            let result = await ShowDetailLoader.loadSeason(key, api: self.api)
            guard self.model?.selectedSeasonKey == key, self.loadingSeasonKey == key else { return }
            switch result {
            case .loaded(let loaded): self.model = self.model?.replacingEpisodes(loaded)
            case .failed: self.model = self.model?.failingEpisodes()
            case .cancelled: return
            }
            self.loadingSeasonKey = nil
            self.rebuild()
        }
    }

    private static func episodeCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 episode") : String(localized: "\(count) episodes")
    }
}

/// The line a season shows instead of episodes: none in it, or it failed to load, with Retry (`TVDetailEpisodesFailedCell`).
@MainActor
final class SeasonMessageView: View {
    var onRetry: (() -> Void)?
    var message = "" { didSet { setNeedsDisplay() } }
    var showsRetry = false { didSet { retry.isHidden = !showsRetry } }
    private let retry = ButtonView(style: .glass, title: String(localized: "Retry", comment: "Button that retries loading the season"))

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        retry.isHidden = true
        retry.onPress = { [weak self] in self?.onRetry?() }
        addSubview(retry)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.primaryControlHeight + Theme.current.metrics.tv(96))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let size = retry.sizeThatFits(bounds.size)
        retry.frame = Rect(x: metrics.sideMargin, y: metrics.tv(64), width: size.width, height: size.height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let layout = TextLayout(message, font: Theme.current.type.callout, maxWidth: bounds.width - Theme.current.metrics.sideMargin * 2, scale: scale)
        context.text(layout, at: Point(x: Theme.current.metrics.sideMargin, y: Theme.current.metrics.tv(16)), color: Theme.current.palette.labelSecondary)
    }
}
