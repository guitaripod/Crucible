import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A movie or episode page (`TVMediaDetailViewController`): Play or Resume with the progress, Start Over, the watched
/// toggle, Rate, Add to Playlist, the Audio and Subtitles menus whose choice playback starts with, Part of a collection,
/// Go to Show and Next Episode for episodes, the watchlist; below, extras, Cast & Crew, More Like This and Information.
@MainActor
final class MediaDetailScreen: DetailScreen {
    private let ratingKey: String
    private let showRatingKey: String?
    private let seasonRatingKey: String?
    private var model: MovieDetailModel?
    private var audioID: Int?
    private var subtitleID: Int?
    /// Whether the viewer picked audio or subtitles here; until then the page shows the tracks playback would start with.
    private var tracksPicked = false
    private var subtitlesBeforeSearch: Set<Int>?
    private var isOnWatchlist: Bool?
    private var watchlistTask: Task<Void, Never>?
    private lazy var scores: [TraktScore] = TraktScores.shared.cached(ratingKey: ratingKey)
    private let extras = ShelfView(header: SectionHeader(title: String(localized: "Extras")), style: .episode)
    private let cast = ShelfView(header: SectionHeader(title: String(localized: "Cast & Crew")), style: .person)
    private let related = ShelfView(header: SectionHeader(title: String(localized: "More Like This")), style: .poster)
    private lazy var rating = RatingSaver(
        api: api,
        ratingKey: ratingKey,
        changed: { [weak self] in self?.rebuild() },
        reload: { [weak self] in self?.reload() },
        failed: { [weak self] in self?.alert(String(localized: "Couldn’t Update"), message: String(localized: "Your rating was not saved.")) }
    )

    init(api: APIClient, ratingKey: String, showRatingKey: String?, seasonRatingKey: String?, placeholder: PlexMetadata?) {
        self.ratingKey = ratingKey
        self.showRatingKey = showRatingKey
        self.seasonRatingKey = seasonRatingKey
        super.init(api: api, placeholder: placeholder)
        extras.onActivate = { [weak self] card in
            guard let self, let extra = self.model?.extras.first(where: { "extra.\($0.id)" == card.id }) else { return }
            self.rootView?.play(item: extra, api: self.api, from: 0)
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
        extras.onPlay = { [weak self] card in
            guard let self, let extra = self.model?.extras.first(where: { "extra.\($0.id)" == card.id }) else { return false }
            self.rootView?.play(item: extra, api: self.api, from: 0)
            return true
        }
        related.onPlay = { [weak self] card in
            guard let self, let item = self.model?.related.first(where: { "related.\($0.id)" == card.id }) else { return false }
            return ItemActions.playPause(item, api: self.api, from: self)
        }
        community.onReshape = { [weak self] in self?.rebuild() }
    }

    override func playFromKey() {
        play(from: nil)
    }

    override func fetch() async {
        fetchScores(ratingKey: ratingKey, cached: scores) { [weak self] in
            self?.scores = $0
            self?.rebuild()
        }
        do {
            guard let loaded = try await MovieDetailLoader.load(api: api, ratingKey: ratingKey, showRatingKey: showRatingKey,
                                                                seasonRatingKey: seasonRatingKey) else {
                if !hasContent { showUnavailable(DetailMessage.itemUnavailable) }
                return
            }
            guard !Task.isCancelled else { return }
            adopt(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            MidgarLog.error("Detail load failed ratingKey=\(ratingKey): \(error)", category: .networking)
            if !hasContent { showFailure(title: String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error)) }
        }
    }

    private func adopt(_ loaded: MovieDetailModel) {
        model = loaded
        rating.loaded()
        let remembered = loaded.isEpisode ? ShowTrackMemory.languages(forShow: loaded.showKey, server: ServerBootstrap.savedMachineIdentifier) : nil
        let tracks = loaded.reconciledTracks(audioId: audioID, subtitleId: subtitleID, viewerPicked: tracksPicked, remembered: remembered,
                                             captionLanguage: nil)
        audioID = tracks.audioId
        subtitleID = tracks.subtitleId
        selectDownloadedSubtitle(in: loaded)
        loadWatchlistState(for: loaded.item)
        community.titleName = loaded.item.title
        rebuild()
        community.load(ratingKey: ratingKey)
    }

    private func rebuild() {
        guard let model else { return }
        let item = model.item
        extras.setItems(model.extras.map {
            CardItem(id: "extra.\($0.id)", artwork: $0.thumb.map { .path($0, .backdrop) }, title: $0.title, subtitle: DetailExtras.subtitle($0),
                     placeholderSymbol: "film")
        })
        cast.setItems(model.castAndCrew.enumerated().map { DetailMapping.person($1, index: $0) })
        related.setItems(DetailMapping.related(model.related))
        information.facts = DetailMapping.facts(model.facts, genres: item.genres)
        var sections: [View] = []
        if !model.extras.isEmpty { sections.append(extras) }
        if !model.castAndCrew.isEmpty { sections.append(cast) }
        sections += community.views
        if !model.related.isEmpty { sections.append(related) }
        if !information.facts.isEmpty { sections.append(information) }
        present(hero: DetailMapping.hero(model.heroInfo(trakt: scores), progress: model.hasProgress ? model.progress.fraction : nil), artwork: model.heroArtwork,
                synopsis: model.hasSummary ? item.summary : nil, synopsisTitle: item.title, actions: actions(for: model), sections: sections)
    }

    private func actions(for model: MovieDetailModel) -> [DetailAction] {
        let item = model.item
        let primary = model.hasProgress ? String(localized: "\(model.playTitle) · \(model.progress.text)") : model.playTitle
        var list = [DetailAction(id: "primary", title: primary, symbol: "play.fill", isPrimary: true, behaviour: .run { [weak self] in self?.play(from: nil) })]
        if model.hasResumePosition {
            list.append(DetailAction(id: "startOver", title: String(localized: "Start Over"), symbol: "arrow.counterclockwise",
                                     behaviour: .run { [weak self] in self?.play(from: 0) }))
        }
        list.append(DetailAction(id: "watched", title: model.watchedToggleTitle, symbol: item.isWatched ? "eye.slash" : "checkmark.circle",
                                 behaviour: .run { [weak self] in self?.markWatched(!item.isWatched) }))
        let current = rating.shown(served: model.userRating)
        list.append(DetailAction(id: "rate", title: UserRatingCopy.actionTitle(for: current), symbol: current == nil ? "star" : "star.fill",
                                 behaviour: .run { [weak self] in self?.presentRating(title: item.title, current: current) }))
        if let checkIn = checkInAction(for: item, done: { [weak self] in self?.rebuild() }) { list.append(checkIn) }
        if item.isPlaylistable {
            list.append(DetailAction(id: "playlist", title: PlaylistFormat.addToPlaylist, symbol: "text.badge.plus", behaviour: .run { [weak self] in
                guard let self, let window = self.window else { return }
                PlaylistPicker.present(adding: [item], api: self.api, in: window)
            }))
        }
        if let value = model.audioButtonValue(selectedId: audioID) {
            list.append(DetailAction(id: "audio", title: String(localized: "Audio: \(value)"), behaviour: audioMenu(for: model)))
        }
        if let value = model.subtitleButtonValue(selectedId: subtitleID) {
            list.append(DetailAction(id: "subtitles", title: String(localized: "Subtitles: \(value)"), behaviour: subtitleMenu(for: model)))
        }
        if let name = model.collectionNames.first {
            let sectionId = item.librarySectionID.map(String.init)
            list.append(DetailAction(id: "collection", title: String(localized: "Part of \(name)"), symbol: "rectangle.stack",
                                     behaviour: .run { [weak self] in self?.openCollection(named: name, sectionId: sectionId) }))
        }
        if model.isEpisode, let route = model.showRoute {
            list.append(DetailAction(id: "goToShow", title: String(localized: "Go to Show"), symbol: "tv", behaviour: .run { [weak self] in self?.push(route) }))
        }
        if model.isEpisode, model.seasonKey != nil {
            list.append(DetailAction(id: "nextEpisode", title: String(localized: "Next Episode"), symbol: "forward.end.fill",
                                     behaviour: .run { [weak self] in self?.goToNextEpisode() }))
        }
        if let onWatchlist = isOnWatchlist, let guid = item.guid {
            list.append(DetailAction(id: "watchlist", title: onWatchlist ? WatchlistService.remove : WatchlistService.add,
                                     symbol: onWatchlist ? "bookmark.slash" : "bookmark",
                                     behaviour: .run { [weak self] in self?.setOnWatchlist(!onWatchlist, guid: guid) }))
        }
        if let manage = manageAction(for: item) { list.append(manage) }
        return list
    }

    private func audioMenu(for model: MovieDetailModel) -> DetailAction.Behaviour {
        let options = model.audioOptions(selectedId: audioID)
        let items = options.enumerated().map { index, option in
            MenuView.Item(id: "\(index)", title: option.title, detail: option.detail, isChecked: option.isSelected)
        }
        return .menu(title: String(localized: "Audio", comment: "Menu title for the audio track options"), items: items) { [weak self] chosen in
            guard let self, let index = Int(chosen.id), options.indices.contains(index) else { return }
            self.audioID = options[index].id
            self.tracksPicked = true
            self.rebuild()
        }
    }

    private func subtitleMenu(for model: MovieDetailModel) -> DetailAction.Behaviour {
        let options = model.subtitleOptions(selectedId: subtitleID).filter(\.isEnabled)
        var items = [MenuView.Item(id: "off", title: String(localized: "Off", comment: "Subtitle option that turns subtitles off"), isChecked: subtitleID == nil)]
        items += options.enumerated().map { index, option in
            MenuView.Item(id: "\(index)", title: option.title, detail: option.detail, isChecked: option.isSelected)
        }
        items.append(MenuView.Item(id: "search", title: SubtitleSearch.title, symbol: "magnifyingglass"))
        return .menu(title: String(localized: "Subtitles", comment: "Menu title for the subtitle options"), items: items) { [weak self] chosen in
            guard let self else { return }
            switch chosen.id {
            case "off":
                self.subtitleID = nil
            case "search":
                self.searchSubtitles(language: SubtitleLanguages.defaultCode())
                return
            default:
                guard let index = Int(chosen.id), options.indices.contains(index) else { return }
                self.subtitleID = options[index].id
            }
            self.tracksPicked = true
            self.rebuild()
        }
    }

    private func play(from position: Double?) {
        guard let model else { return }
        let resume = position ?? model.resumePosition(offlineResumeSecs: nil)
        rootView?.play(item: model.item, api: api, from: resume, tracks: tracksPicked ? (audioID, subtitleID) : nil)
    }

    /// Flips the button the moment it is pressed, then tells the server and reloads; a failure flips it back and says so.
    private func markWatched(_ watched: Bool) {
        guard let model else { return }
        let key = model.item.id
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(watched, ratingKey: key, api: self.api)
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

    private func person(_ id: String) -> PlexRole? {
        guard let index = Int(id.dropFirst("cast.".count)), let roles = model?.castAndCrew, roles.indices.contains(index) else { return nil }
        return PersonFilmography.canOpen(roles[index]) ? roles[index] : nil
    }

    private func goToNextEpisode() {
        guard let seasonKey = model?.seasonKey else { return }
        let ratingKey = ratingKey
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let next = try await MovieDetailLoader.nextEpisode(after: ratingKey, inSeason: seasonKey, api: self.api),
                      let route = self.model?.nextEpisodeRoute(next) else { return }
                self.push(route)
            } catch {
                MidgarLog.error("Next episode lookup failed ratingKey=\(ratingKey): \(error)", category: .networking)
            }
        }
    }

    /// Finds out once whether the title is on the watchlist, so the page can offer the button that fits; an episode, a
    /// title without a guid or an account that cannot be reached leaves the button out.
    private func loadWatchlistState(for item: PlexMetadata) {
        guard isOnWatchlist == nil, watchlistTask == nil, let guid = item.guid, ["movie", "show"].contains(item.mediaType) else { return }
        let token = api.token
        watchlistTask = Task { [weak self] in
            guard let watchlist = try? await WatchlistService.items(token: token), !Task.isCancelled else { return }
            self?.isOnWatchlist = WatchlistService.contains(guid: guid, in: watchlist)
            self?.rebuild()
        }
    }

    private func setOnWatchlist(_ wanted: Bool, guid: String) {
        let token = api.token
        isOnWatchlist = wanted
        rebuild()
        Task { [weak self] in
            do {
                if wanted {
                    try await WatchlistService.add(guid: guid, token: token)
                } else {
                    try await WatchlistService.remove(guid: guid, token: token)
                }
            } catch {
                self?.isOnWatchlist = !wanted
                self?.rebuild()
                self?.alert(String(localized: "Couldn’t Update"), message: ConnectionError.message(for: error))
            }
        }
    }

    // MARK: Subtitle search

    private func searchSubtitles(language: String) {
        guard let model else { return }
        subtitlesBeforeSearch = Set(model.item.subtitleStreams.compactMap(\.id))
        let ratingKey = ratingKey
        Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await SubtitleSearch.search(ratingKey: ratingKey, language: language, api: self.api)
                self.presentSubtitleChoices(found, language: language)
            } catch {
                MidgarLog.error("Subtitle search failed ratingKey=\(ratingKey): \(error)", category: .networking)
                self.alert(String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error))
            }
        }
    }

    private func presentSubtitleChoices(_ found: [PlexSubtitleCandidate], language: String) {
        guard let window else { return }
        let name = SubtitleLanguages.name(for: language)
        var actions = found.prefix(8).map { candidate in
            let title = [candidate.perfectMatch ? "★" : nil, candidate.title, candidate.providerTitle].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
            return AlertView.Action(title.isEmpty ? name : title) { [weak self] in self?.downloadSubtitle(candidate, language: language) }
        }
        actions.append(AlertView.Action(String(localized: "\(SubtitleSearch.languageTitle): \(name)")) { [weak self] in self?.chooseSubtitleLanguage() })
        actions.append(AlertView.Action(String(localized: "Cancel"), role: .cancel))
        AlertView(title: "\(SubtitleSearch.screenTitle) · \(name)", message: found.isEmpty ? SubtitleSearch.emptyText : nil, actions: Array(actions))
            .present(in: window)
    }

    private func chooseSubtitleLanguage() {
        guard let window else { return }
        let items = SubtitleLanguages.codes.map { MenuView.Item(id: $0, title: SubtitleLanguages.name(for: $0)) }
        let center = Rect(x: window.contentView.bounds.midX - 200, y: window.contentView.bounds.height * 0.2, width: 1, height: 1)
        let menu = MenuView(title: SubtitleSearch.languageTitle, items: items, anchor: center)
        menu.onSelect = { [weak self] chosen in self?.searchSubtitles(language: chosen.id) }
        menu.present(in: window)
    }

    private func downloadSubtitle(_ candidate: PlexSubtitleCandidate, language: String) {
        let ratingKey = ratingKey
        Task { [weak self] in
            guard let self else { return }
            do {
                try await SubtitleSearch.download(candidate, ratingKey: ratingKey, language: language, api: self.api)
                self.reload()
            } catch {
                self.alert(String(localized: "Couldn’t Download"), message: ConnectionError.message(for: error))
            }
        }
    }

    /// Once a downloaded subtitle shows up in the title's tracks it is the one selected.
    private func selectDownloadedSubtitle(in model: MovieDetailModel) {
        guard let before = subtitlesBeforeSearch,
              let added = model.item.subtitleStreams.compactMap(\.id).first(where: { !before.contains($0) }) else { return }
        subtitlesBeforeSearch = nil
        subtitleID = added
        tracksPicked = true
    }
}
