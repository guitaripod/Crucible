import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A title's page (`TVMediaDetailViewController`, `TVShowDetailViewController`): the backdrop, the hero, the actions, and
/// below them the seasons and episodes of a show, the cast, and related titles.
@MainActor
final class DetailScreen: ScreenView {
    private let api: APIClient
    private var item: PlexMetadata
    private var movie: MovieDetailModel?
    private var show: ShowDetailModel?
    private let backdrop = BackdropView()
    private let hero = HeroInfoView()
    private let page = PageView()
    private let heroRoom = SpacerView(height: 0)
    private let actions = ActionRowView()
    private let seasons = ChipRowView()
    private let episodes = ShelfView(header: nil, style: .episode)
    private let cast = ShelfView(header: SectionHeader(title: String(localized: "Cast & Crew")), style: .person)
    private let related = ShelfView(header: SectionHeader(title: String(localized: "More Like This")), style: .poster)
    private let state = StateView()
    private var loadTask: Task<Void, Never>?

    init(api: APIClient, item: PlexMetadata) {
        self.api = api
        self.item = item
        super.init()
        [backdrop, hero, page, state].forEach(addSubview)
        page.setSections([heroRoom, actions])
        page.onScroll = { [weak self] offset in
            guard let self else { return }
            self.hero.translation = Point(x: 0, y: -offset)
            self.backdrop.dimming = min(max(offset / max(self.heroRoom.height * 0.8, 1), 0), 1)
            self.rootView?.contentScrolled(offset: offset)
        }
        state.isHidden = true
        seasons.onSelect = { [weak self] chip in self?.selectSeason(chip.id) }
        episodes.onActivate = { [weak self] card in
            guard let self, let episode = self.show?.episodes.first(where: { $0.id == card.id }) else { return }
            self.rootView?.push(DetailScreen(api: self.api, item: episode))
        }
        related.onActivate = { [weak self] card in
            guard let self, let media = self.movie?.related.first(where: { $0.id == card.id }) else { return }
            self.rootView?.push(DetailScreen(api: self.api, item: media))
        }
        hero.configure(HeroInfo(title: item.title, synopsis: item.summary), animated: false)
        let art = item.art ?? item.grandparentArt
        backdrop.show(art.map { .path($0, .backdrop) }, immediate: true)
    }

    override var preferredFocusView: View? { state.isHidden ? actions : state }

    override func screenDidAppear() {
        if movie == nil && show == nil { load() }
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    private func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if item.mediaType == "show" {
                    let model = try await ShowDetailLoader.load(api: api, showRatingKey: item.id, initialSeasonKey: nil,
                                                                selectedSeasonKey: { [weak self] in self?.show?.selectedSeasonKey },
                                                                onShow: { [weak self] show in self?.item = show })
                    guard !Task.isCancelled else { return }
                    guard let model else { return unavailable(DetailMessage.showUnavailable) }
                    show = model
                } else {
                    let model = try await MovieDetailLoader.load(api: api, ratingKey: item.id)
                    guard !Task.isCancelled else { return }
                    guard let model else { return unavailable(DetailMessage.itemUnavailable) }
                    movie = model
                    item = model.item
                }
                render()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                state.isHidden = false
                state.show(.error(title: String(localized: "Couldn’t Load This Title"), message: ConnectionError.message(for: error),
                                  retryTitle: String(localized: "Try Again"), retry: { [weak self] in self?.load() }))
            }
        }
    }

    private func unavailable(_ message: String) {
        state.isHidden = false
        state.show(.empty(title: String(localized: "Not Available"), message: message, symbol: "exclamationmark.triangle", action: nil))
    }

    private func render() {
        var sections: [View] = [heroRoom, actions]
        if let movie {
            let info = movie.heroInfo
            hero.configure(HeroInfo(eyebrow: info.eyebrow, title: info.title, metaParts: info.meta.leading, badges: info.badges,
                                    synopsis: movie.item.summary, progress: movie.hasProgress ? movie.progress.fraction : nil), animated: true)
            let artwork = movie.heroArtwork
            if let path = artwork.path { backdrop.show(.path(path, artwork.isBackdrop ? .backdrop : .poster), immediate: true) }
            actions.configure(play: movie.playTitle, watched: movie.watchedToggleTitle, onPlay: { [weak self] in self?.play() },
                              onWatched: { [weak self] in self?.toggleWatched() })
            let people = movie.castAndCrew.prefix(30).enumerated().map { index, role in
                CardItem(id: "\(index)-\(role.tag ?? "")", artwork: role.thumb.map { .url(URL(string: $0)!) }, title: role.tag ?? "",
                         subtitle: role.role, placeholderSymbol: "person")
            }
            if !people.isEmpty {
                cast.setItems(Array(people))
                sections.append(cast)
            }
            let more = movie.related.prefix(20).map { media in
                CardItem(id: media.id, artwork: (media.thumb).map { .path($0, .poster) }, title: media.title,
                         subtitle: media.year.map(String.init), placeholderSymbol: "film")
            }
            if !more.isEmpty {
                related.setItems(Array(more))
                sections.append(related)
            }
        } else if let show {
            let info = show.heroInfo
            hero.configure(HeroInfo(eyebrow: info.eyebrow, title: info.title, metaParts: info.meta.leading, badges: info.badges,
                                    synopsis: show.show.summary), animated: true)
            actions.configure(play: String(localized: "Play"), watched: WatchedService.title(isWatched: show.isWatched),
                              onPlay: { [weak self] in self?.play() }, onWatched: { [weak self] in self?.toggleWatched() })
            seasons.setChips(show.seasonChips.map {
                ChipRowView.Chip(id: $0.id, title: $0.title, isSelected: $0.isSelected, isDimmed: $0.isMissing)
            })
            sections.append(seasons)
            episodes.header = SectionHeader(title: show.selectedSeasonTitle, secondaryText: show.selectedSeasonWatchedText)
            episodes.setItems(show.episodeRows(showingSkipped: true).compactMap { row -> CardItem? in
                guard case .episode(let episode) = row else { return nil }
                let progress = episode.progressFraction
                return CardItem(id: episode.id, artwork: episode.thumb.map { .path($0, .backdrop) },
                                title: "\(episode.index ?? 0)  ·  \(episode.title)", subtitle: DetailFormat.runtime(episode.durationSecs),
                                eyebrow: nil, progress: progress > 0 && progress < 1 ? progress : nil,
                                isUnwatched: !episode.isWatched && progress <= 0, isWatched: episode.isWatched, placeholderSymbol: "tv")
            })
            sections.append(episodes)
        }
        page.setSections(sections)
        setNeedsLayout()
    }

    private func selectSeason(_ key: String) {
        guard let current = show else { return }
        show = current.selectingSeason(key).loadingSeason(key)
        render()
        Task { [weak self] in
            guard let self else { return }
            let episodes = await ShowDetailLoader.episodes(inSeason: key, api: api)
            guard let updated = self.show, updated.selectedSeasonKey == key else { return }
            self.show = episodes.map { updated.replacingEpisodes($0) } ?? updated.failingEpisodes()
            self.render()
        }
    }

    private func play() {
        MidgarLog.notice("Play requested for \(item.id)", category: .playback)
        rootView?.play(item: movie?.item ?? item, api: api)
    }

    private func toggleWatched() {
        let watched = movie.map { !$0.item.isWatched } ?? !(show?.isWatched ?? false)
        let key = movie?.item.id ?? item.id
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(watched, ratingKey: key, api: api)
                load()
            } catch {
                MidgarLog.error("Watched toggle failed: \(error)", category: .networking)
            }
        }
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        backdrop.frame = bounds
        page.frame = bounds
        state.frame = bounds
        let heroHeight = max(metrics.heroHeight, frame.height * 0.55)
        heroRoom.height = heroHeight
        hero.frame = Rect(x: metrics.sideMargin, y: metrics.heroTopClearance, width: frame.width - metrics.sideMargin * 2,
                          height: heroHeight - metrics.heroTopClearance - metrics.heroBottomClearance)
        page.setNeedsLayout()
    }
}

/// The detail actions: Play (or Resume) and the watched toggle.
@MainActor
final class ActionRowView: View {
    private let play = ButtonView(style: .primary, title: nil, symbol: "play.fill")
    private let watched = ButtonView(style: .glass, title: nil, symbol: "checkmark")

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(play)
        addSubview(watched)
    }

    override var preferredFocusView: View? { play }
    override var remembersFocus: Bool { true }

    func configure(play title: String, watched watchedTitle: String, onPlay: @escaping () -> Void, onWatched: @escaping () -> Void) {
        play.title = title
        play.onPress = onPlay
        watched.title = watchedTitle
        watched.onPress = onWatched
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.primaryControlHeight + Theme.current.metrics.tv(48))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        var x = metrics.sideMargin
        for button in [play, watched] {
            let size = button.sizeThatFits(Size(width: 600, height: 200))
            button.frame = Rect(x: x, y: 0, width: size.width, height: size.height)
            x += size.width + metrics.tv(32)
        }
    }
}
