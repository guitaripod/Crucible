import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A show page (`TVShowDetailViewController`): Play Up Next or Continue, the Essentials offer and Episodes menu (levels,
/// retold arcs, skipped episodes, highlights and Spoiler Shield), the Watched menu for the show and its season, Rate and Add
/// to Playlist; the season chips with what is watched of each, including seasons only the catalogue knows, the season's
/// episodes with the aired ones the server lacks (selecting one plays it, a right click offers Play, Play from Beginning,
/// Watched, Keep or Hide Again and Episode Details), Cast & Crew and More Like This.
@MainActor
final class ShowDetailScreen: DetailScreen {
    private let showKey: String
    private lazy var scores: [TraktScore] = TraktScores.shared.cached(ratingKey: showKey)
    private let initialSeasonKey: String?
    private var model: ShowDetailModel?
    private var loadingSeasonKey: String?
    private var seasonTask: Task<Void, Never>?
    private var gapsTask: Task<Void, Never>?
    private var showsSkipped = false
    private var highlightsOnly = false
    /// Whether the season the page was opened on, when the server lacks it, has been shown once the catalogue answered.
    private var openedInitialMissingSeason = false
    /// The viewer chose a season themselves, which a late catalogue answer never overrides.
    private var viewerPickedSeason = false
    /// Seerr says the show is missing seasons nobody asked for, which adds Request More Seasons.
    private var offersRequest = false
    private var requestTask: Task<Void, Never>?
    private var missingByID: [String: MissingEpisode] = [:]
    private let seasons = ChipRowView()
    private let episodes = ShelfView(header: nil, style: .episode)
    /// The season's episodes as a list, in the Desktop layout.
    private let episodeList = EpisodeListView()
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
        seasons.onSelect = { [weak self] chip in
            self?.viewerPickedSeason = true
            self?.selectSeason(chip.id)
        }
        episodes.onActivate = { [weak self] card in
            guard let self else { return }
            if let episode = self.episode(card.id) {
                self.rootView?.play(item: episode, api: self.api)
            } else if self.missingByID[card.id] != nil {
                self.requestMissing()
            }
        }
        episodes.onContextMenu = { [weak self] card, point in
            guard let self else { return }
            if let episode = self.episode(card.id) {
                self.presentEpisodeMenu(episode, at: point, from: self.episodes.card(for: card.id))
            } else if self.missingByID[card.id] != nil {
                self.presentMissingMenu(card, at: point, from: self.episodes.card(for: card.id))
            }
        }
        episodeList.onActivate = episodes.onActivate
        episodeList.onContextMenu = { [weak self] card, point in
            guard let self else { return }
            if let episode = self.episode(card.id) {
                self.presentEpisodeMenu(episode, at: point, from: self.episodeList.row(for: card.id))
            } else if self.missingByID[card.id] != nil {
                self.presentMissingMenu(card, at: point, from: self.episodeList.row(for: card.id))
            }
        }
        community.onReshape = { [weak self] in self?.rebuild() }
        episodesFailed.onRetry = { [weak self] in
            guard let key = self?.model?.selectedSeasonKey else { return }
            self?.loadSeason(key)
        }
        cast.onActivate = { [weak self] card in
            guard let self, let person = self.person(card.id) else { return }
            self.openPerson(person)
        }
        cast.onContextMenu = { [weak self] card, point in self?.presentPersonMenu(card, at: point) }
        related.onActivate = { [weak self] card in
            guard let self, let item = self.model?.related.first(where: { "related.\($0.id)" == card.id }) else { return }
            self.push(.related(item))
        }
        related.onContextMenu = { [weak self] card, point in
            guard let self, let item = self.model?.related.first(where: { "related.\($0.id)" == card.id }) else { return }
            ItemActions.present(for: item, api: self.api, at: point, in: self) { [weak self] in self?.reload() }
        }
        episodes.onToggleWatched = { [weak self] card in
            guard let self, let episode = self.episode(card.id) else { return }
            self.markWatched(!card.isWatched, ratingKey: episode.id)
        }
        episodeList.onToggleWatched = episodes.onToggleWatched
        episodes.onPlay = { [weak self] card in
            guard let self, let episode = self.episode(card.id) else { return false }
            self.rootView?.play(item: episode, api: self.api)
            return true
        }
        related.onPlay = { [weak self] card in
            guard let self, let item = self.model?.related.first(where: { "related.\($0.id)" == card.id }) else { return false }
            return ItemActions.playPause(item, api: self.api, from: self)
        }
        episodeList.onPlay = episodes.onPlay
    }

    /// Play/Pause with no episode under focus plays Up Next, as the show's Play button does.
    override func playFromKey() {
        playUpNext()
    }

    override func fetch() async {
        fetchScores(ratingKey: showKey, cached: scores) { [weak self] in
            self?.scores = $0
            self?.rebuild()
        }
        do {
            let model = try await ShowDetailLoader.load(api: api, showRatingKey: showKey, initialSeasonKey: initialSeasonKey,
                                                        selectedSeasonKey: { [weak self] in self?.model?.selectedSeasonKey },
                                                        onShow: { [weak self] show in
                                                            self?.showArrived(show)
                                                            self?.loadRequestState(for: show)
                                                        })
            guard !Task.isCancelled else { return }
            guard let model else {
                if !hasContent { showUnavailable(DetailMessage.showUnavailable) }
                return
            }
            seasonTask?.cancel()
            loadingSeasonKey = nil
            let (kept, follow) = Self.keepingGaps(of: self.model, in: model)
            self.model = kept
            rating.loaded()
            community.titleName = kept.show.title
            rebuild()
            community.load(ratingKey: showKey)
            if let follow { loadSeason(follow) }
            loadGaps()
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

    /// The layout the episodes were last laid out for: a switch of layout lays them out again as a shelf or a list.
    private var builtDensity = Theme.current.density

    override func layoutSubviews() {
        if builtDensity != Theme.current.density { rebuild() }
        super.layoutSubviews()
    }

    private func rebuild() {
        builtDensity = Theme.current.density
        guard let model else { return }
        let shield = SpoilerShield.isOn(showKey)
        let highlightKeys = model.highlightKeys
        let rows = model.episodeRows(showingSkipped: showsSkipped, highlights: highlightsOnly && model.essentials == nil ? highlightKeys : nil)
        var cards: [CardItem] = []
        missingByID = [:]
        for row in rows {
            switch row {
            case .episode(let episode):
                let shielded = shield && !episode.isWatched
                cards.append(card(for: episode, status: model.status(for: episode, shielded: shielded, highlights: highlightKeys), shielded: shielded))
            case .missing(let missing):
                missingByID[missing.id] = missing
                cards.append(missingCard(missing, shielded: shield))
            }
        }
        seasons.setChips(model.seasonChips.map {
            ChipRowView.Chip(id: $0.id, title: [$0.title, $0.watchedText].compactMap { $0 }.joined(separator: "  ·  "), isSelected: $0.isSelected,
                             isDimmed: $0.isMissing)
        })
        let loading = loadingSeasonKey != nil
        episodes.header = SectionHeader(title: model.selectedSeasonTitle,
                                        secondaryText: loading || model.episodesFailed ? nil : Self.episodesDetail(model, count: Self.countedEpisodes(model, rows: rows)))
        episodes.setItems(cards)
        episodeList.header = episodes.header
        episodeList.setItems(cards)
        let roles = MovieDetailModel(item: model.show).castAndCrew
        cast.setItems(roles.enumerated().map { DetailMapping.person($1, index: $0) })
        related.setItems(DetailMapping.related(model.related))
        var sections: [View] = []
        if !model.seasonChips.isEmpty { sections.append(seasons) }
        if model.selectedSeason != nil || model.selectedMissingSeason != nil {
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
                sections.append(Theme.current.density == .desk ? episodeList : episodes)
            }
        }
        if !roles.isEmpty { sections.append(cast) }
        sections += community.views
        if !model.related.isEmpty { sections.append(related) }
        present(hero: DetailMapping.hero(model.heroInfo(trakt: scores), progress: nil), artwork: model.heroArtwork,
                synopsis: model.hasSummary ? model.show.summary : nil, synopsisTitle: model.show.title, actions: actions(for: model), sections: sections)
    }

    /// An episode card as the Apple TV draws it: number and title, runtime or air date, an eyebrow for Continue and Up Next,
    /// progress, and watched or skipped episodes dimmed; under Spoiler Shield an unwatched one is "Episode N" with no still.
    private func card(for episode: PlexMetadata, status: EpisodeStatus, shielded: Bool) -> CardItem {
        let number = status.episodeNumber.map { "\($0)  ·  " } ?? ""
        return CardItem(id: "episode.\(episode.id)", artwork: shielded ? nil : episode.thumb.map { .path($0, .backdrop) },
                        title: shielded ? status.title : number + status.title, subtitle: status.metaText.isEmpty ? nil : status.metaText,
                        eyebrow: Self.eyebrow(for: status.marker), progress: status.progress, isWatched: status.isWatched,
                        isDimmed: status.isWatched || status.isSkipped, placeholderSymbol: "tv").linked(to: episode).summarised(shielded ? nil : episode.summary)
    }

    /// An aired episode the server lacks, dimmed with "Not on your server" (`TVDetailMapping.missingEpisode`), offering a
    /// Seerr request where a server episode offers Play and no watched mark.
    private func missingCard(_ missing: MissingEpisode, shielded: Bool) -> CardItem {
        let status = EpisodeStatus(missing: missing, shielded: shielded)
        var card = CardItem(id: missing.id, artwork: shielded ? nil : missing.thumb.map { .path($0, .backdrop) },
                            title: shielded ? status.title : "\(missing.episode)  ·  " + status.title, subtitle: status.metaText.isEmpty ? nil : status.metaText,
                            eyebrow: Self.eyebrow(for: status.marker), isDimmed: true, placeholderSymbol: "tv")
        card.primarySymbol = "plus"
        card.primaryName = SeerrCopy.request
        card.canToggleWatched = false
        return card
    }

    /// The menu of an episode the server lacks: Request, which asks Seerr for the show's missing seasons.
    private func presentMissingMenu(_ card: CardItem, at point: Point?, from view: View?) {
        guard let window else { return }
        let frame = view?.frameInWindow ?? frameInWindow
        let menu = MenuView(title: card.title, items: [MenuView.Item(id: "request", title: SeerrCopy.request, symbol: "plus.circle")],
                            anchor: point.map { Rect(x: $0.x, y: $0.y, width: 1, height: 1) } ?? frame)
        menu.onSelect = { [weak self] _ in self?.requestMissing() }
        menu.present(in: window)
    }

    private static func eyebrow(for marker: EpisodeStatus.Marker?) -> String? {
        switch marker {
        case .inProgress: String(localized: "Continue", comment: "Action title that resumes a partly watched item")
        case .upNext: String(localized: "Up Next")
        case .missing: ShowGapsCopy.notOnServer
        default: nil
        }
    }

    /// Asks Seerr for what the server lacks of the show, or says how to connect Seerr when it is not, naming the aired
    /// episodes the server lacks for a season Seerr takes no request for.
    private func requestMissing() {
        guard let model else { return }
        let missing = model.gaps.episodes.values.joined().map { SeerrMissingEpisode(season: $0.season, episode: $0.episode, title: $0.title) }
        SeerrRequestScreen.open(model.show, api: api, isOnServer: true, missing: missing, from: self)
    }

    /// Asks Seerr whether the show is missing seasons nobody asked for, which adds Request More Seasons; the page never
    /// waits for it.
    private func loadRequestState(for show: PlexMetadata) {
        guard SeerrAccount.shared.isConnected else { return }
        let api = api
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            let state = try? await SeerrTitles.shared.state(for: show, api: api)
            guard !Task.isCancelled, let self else { return }
            let offers = state?.canRequest(with: SeerrAccount.shared.permissions) ?? false
            guard offers != self.offersRequest else { return }
            self.offersRequest = offers
            self.rebuild()
        }
    }

    private func actions(for model: ShowDetailModel) -> [DetailAction] {
        var list = [DetailAction(id: "primary", title: model.primaryTitle, symbol: "play.fill", isPrimary: true, isEnabled: model.isPrimaryEnabled,
                                 behaviour: .run { [weak self] in self?.playUpNext() })]
        if PreviouslyOnRequest.offer(model) != .none {
            list.append(DetailAction(id: "previouslyOn", title: CompanionCopy.previouslyOn, symbol: "text.quote", behaviour: .run { [weak self] in
                guard let self, let model = self.model else { return }
                PreviouslyOnPresenter.present(model, from: self)
            }))
        }
        if let plan = model.essentials, EssentialsCopy.shouldOffer(plan) {
            let preview = plan.preview(EssentialsChoice(level: .skipAnimeOnly))
            list.append(DetailAction(id: "essentialsOffer",
                                     title: String(localized: "Skip \(preview.hidden) Anime-Only · Save \(EssentialsCopy.duration(preview.seconds))",
                                                   comment: "Button that turns on Skip Anime-Only, e.g. Skip 21 Anime-Only · Save 8 h 6 min"),
                                     symbol: "sparkles", behaviour: .run { [weak self] in self?.answerOffer() }))
        }
        list.append(essentialsAction(for: model))
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
        if offersRequest {
            list.append(DetailAction(id: "request", title: SeerrCopy.requestMore, symbol: "plus.rectangle.on.rectangle", behaviour: .run { [weak self] in
                guard let self else { return }
                SeerrRequestScreen.open(show, api: self.api, isOnServer: true, from: self)
            }))
        }
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

    // MARK: Essentials

    /// The Episodes button: Essentials' levels with what each hides, the retold arc, Show Skipped, or without a guide the
    /// Highlights filter; Spoiler Shield on every show. Its title says the level in use.
    private func essentialsAction(for model: ShowDetailModel) -> DetailAction {
        var items: [MenuView.Item] = []
        if let plan = model.essentials {
            items += EssentialsLevel.allCases.map { level in
                MenuView.Item(id: "level.\(level.rawValue)", title: level.title, detail: EssentialsCopy.levelSubtitle(plan, level: level),
                              isChecked: plan.choice.level == level)
            }
            if let range = plan.guide.ranges.first {
                items.append(MenuView.Item(id: "retold", title: EssentialsCopy.retoldTitle(range), detail: EssentialsCopy.retoldSubtitle(range), symbol: "film",
                                           isChecked: plan.choice.seenRetold))
            }
            if !plan.hiddenKeys.isEmpty {
                items.append(MenuView.Item(id: "skipped", title: EssentialsCopy.showSkipped, symbol: "eye", isChecked: showsSkipped))
            }
        } else if !model.highlightKeys.isEmpty {
            items.append(MenuView.Item(id: "highlights.off", title: EssentialsLevel.all.title, isChecked: !highlightsOnly))
            items.append(MenuView.Item(id: "highlights.on", title: Highlights.title, detail: Highlights.subtitle, isChecked: highlightsOnly))
        }
        items.append(MenuView.Item(id: "shield", title: SpoilerShield.title, detail: SpoilerShield.subtitle, symbol: "eye.slash", isChecked: SpoilerShield.isOn(showKey)))
        let title = model.essentials.map { EssentialsCopy.title + " · " + EssentialsCopy.sourceLine($0.guide) } ?? EssentialsCopy.title
        let shown = model.essentials.map(EssentialsCopy.barTitle) ?? (highlightsOnly ? Highlights.title : EssentialsLevel.all.title)
        return DetailAction(id: "essentials", title: shown, symbol: "line.3.horizontal.decrease",
                            behaviour: .menu(title: title, items: items) { [weak self] chosen in self?.chooseEssentials(chosen.id) })
    }

    private func chooseEssentials(_ id: String) {
        guard let model else { return }
        switch id {
        case "shield":
            SpoilerShield.set(showKey, on: !SpoilerShield.isOn(showKey))
            rebuild()
        case "skipped":
            showsSkipped.toggle()
            rebuild()
        case "highlights.on", "highlights.off":
            highlightsOnly = id == "highlights.on"
            rebuild()
        case "retold":
            guard var choice = model.essentials?.choice else { return }
            choice.seenRetold.toggle()
            choice.offered = true
            saveEssentials(choice)
        default:
            guard id.hasPrefix("level."), let level = EssentialsLevel(rawValue: String(id.dropFirst("level.".count))),
                  var choice = model.essentials?.choice else { return }
            choice.level = level
            choice.offered = true
            saveEssentials(choice)
        }
    }

    private func saveEssentials(_ choice: EssentialsChoice) {
        Task { [weak self] in
            guard let self else { return }
            let plan = await EssentialsCenter.shared.save(choice, showRatingKey: self.showKey)
            self.model = self.model?.replacingEssentials(plan)
            self.rebuild()
        }
    }

    /// The offer's answer: Skip Anime-Only on, and the offer never comes back.
    private func answerOffer() {
        guard var choice = model?.essentials?.choice else { return }
        choice.offered = true
        choice.level = .skipAnimeOnly
        saveEssentials(choice)
    }

    /// The line beside the season's name: what Essentials hides, else how many episodes are listed, and for a season the
    /// server lacks, that it is not there.
    private static func episodesDetail(_ model: ShowDetailModel, count: Int) -> String {
        if model.selectedMissingSeason != nil { return [ShowGapsCopy.notOnServer, episodeCount(count)].joined(separator: "  ·  ") }
        return model.essentials.flatMap { EssentialsCopy.seasonDetail($0, season: model.episodes) } ?? episodeCount(count)
    }

    /// The episodes the header counts: what the season lists, but for a season the server has, only the episodes on it.
    private static func countedEpisodes(_ model: ShowDetailModel, rows: [ShowDetailModel.EpisodeRow]) -> Int {
        guard model.selectedMissingSeason == nil else { return rows.count }
        return rows.filter { if case .episode = $0 { true } else { false } }.count
    }

    // MARK: What the server lacks

    /// A reload keeps what the catalogue said, and a season the server lacks stays open, until the next look answers; once
    /// the server has that season, the page moves to it (`follow`).
    private static func keepingGaps(of previous: ShowDetailModel?, in loaded: ShowDetailModel) -> (model: ShowDetailModel, follow: String?) {
        guard let previous, !previous.gaps.isEmpty else { return (loaded, nil) }
        let kept = loaded.replacingGaps(previous.gaps)
        guard let open = previous.selectedMissingSeason else { return (kept, nil) }
        if let arrived = loaded.seasons.first(where: { $0.index == open.index }) {
            return (kept, arrived.id == loaded.selectedSeasonKey ? nil : arrived.id)
        }
        return (kept.selectingSeason(open.id).replacingEpisodes([]), nil)
    }

    /// Asks Plex's catalogue what has aired that the server lacks, once every episode on the server is known; the page never
    /// waits for it.
    private func loadGaps() {
        guard let loaded = model, !loaded.allEpisodes.isEmpty || loaded.seasons.isEmpty else { return }
        let show = loaded.show, episodes = loaded.allEpisodes, check = ShowGapsCheck.live(api: api)
        gapsTask?.cancel()
        gapsTask = Task { [weak self] in
            guard let gaps = await ShowGapsCenter.shared.gaps(show: show, serverEpisodes: episodes, check: check),
                  !Task.isCancelled, let self, let current = self.model else { return }
            self.adoptGaps(gaps.keepingOpened(from: current.gaps), in: current)
        }
    }

    /// Puts a look's answer on screen: opens the missing season the page was opened on, once and only while the viewer has
    /// not picked a season; leaves a missing season that is no longer missing; and lists an open missing season whose
    /// episodes the answer does not carry yet.
    private func adoptGaps(_ gaps: ShowGaps, in current: ShowDetailModel) {
        let updated = current.replacingGaps(gaps)
        let initial = openedInitialMissingSeason ? nil : gaps.season(id: initialSeasonKey)
        openedInitialMissingSeason = true
        if let initial, !viewerPickedSeason, !updated.seasons.contains(where: { $0.index == initial.index }) {
            model = updated
            loadSeason(initial.id)
            return
        }
        if updated.leftMissingSeason, let target = updated.arrivedSeason ?? updated.seasons.first {
            model = updated
            loadSeason(target.id)
            return
        }
        if updated.needsMissingEpisodes, let missing = updated.selectedMissingSeason, loadingSeasonKey != missing.id {
            model = updated
            loadSeason(missing.id)
            return
        }
        guard updated.gaps != current.gaps else { return }
        model = updated
        rebuild()
    }

    /// Lists the aired episodes of a season the server has none of, asking the catalogue for them the first time.
    private func openMissingSeason(_ missing: MissingSeason, key: String) {
        guard let current = model else { return }
        let show = current.show, gaps = current.gaps, check = ShowGapsCheck.live(api: api)
        seasonTask?.cancel()
        seasonTask = Task { [weak self] in
            guard let self else { return }
            let filled = await ShowGapsCenter.shared.opening(missing, of: show, in: gaps, check: check)
            guard !Task.isCancelled, self.model?.selectedSeasonKey == key, self.loadingSeasonKey == key else { return }
            self.model = filled.map { self.model?.replacingGaps($0) } ?? self.model?.failingEpisodes()
            self.loadingSeasonKey = nil
            self.rebuild()
        }
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
        let plan = model.essentials
        let number = plan?.wouldHide(episode.id) == true ? plan?.number(of: episode.id) : nil
        let kept = plan.map { !$0.hides(episode.id) } ?? false
        if number != nil {
            items.append(MenuView.Item(id: "essentials", title: kept ? EssentialsCopy.hideAgain : EssentialsCopy.keep, symbol: kept ? "minus.circle" : "plus.circle"))
        }
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
            case "essentials":
                guard var choice = plan?.choice, let number else { return }
                if kept { choice.kept.remove(number) } else { choice.kept.insert(number) }
                self.saveEssentials(choice)
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
        guard current.selectedSeasonKey != key || current.episodesFailed || current.needsMissingEpisodes else { return }
        loadSeason(key)
    }

    /// Shows `key` loading at once and fills it when its episodes arrive; a response for a season no longer selected is
    /// dropped, so a slow earlier pick cannot replace a later one.
    private func loadSeason(_ key: String) {
        guard let current = model else { return }
        model = current.loadingSeason(key)
        loadingSeasonKey = key
        rebuild()
        if let missing = current.gaps.season(id: key) {
            openMissingSeason(missing, key: key)
            return
        }
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
