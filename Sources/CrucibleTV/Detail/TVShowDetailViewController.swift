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
    private var scores: [TraktScore] = []
    private var offersRequest = false
    private lazy var seasonSlot = makeTaskSlot()
    private var loadingSeasonKey: String?
    private var episodesByID: [String: PlexMetadata] = [:]
    private var showsSkipped = false
    private var highlightsOnly = false
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
            let isFirst = model == nil
            model = loaded
            rating.loaded()
            rebuild()
            if isFirst { loadScores() }
            loadRequestState()
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
        if let plan = model.essentials, plan.wouldHide(episode.id), let n = plan.number(of: episode.id) {
            let kept = !plan.hides(episode.id)
            children.append(UIAction(title: kept ? EssentialsCopy.hideAgain : EssentialsCopy.keep, image: UIImage(systemName: kept ? "minus.circle" : "plus.circle")) { [weak self] _ in
                var choice = plan.choice
                if kept { choice.kept.remove(n) } else { choice.kept.insert(n) }
                self?.saveEssentials(choice)
            })
        }
        children.append(UIAction(title: String(localized: "Episode Details"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.push(.item(ratingKey: episode.id, mediaType: "episode", showRatingKey: self?.showKey, seasonRatingKey: model.selectedSeasonKey))
        })
        return UIMenu(children: children)
    }

    private func rebuild() {
        guard let model else { return }
        let shield = SpoilerShield.isOn(showKey)
        let highlightKeys = model.highlightKeys
        let episodes = model.visibleEpisodes(showingSkipped: showsSkipped, highlights: highlightsOnly && model.essentials == nil ? highlightKeys : nil)
        let episodeCards = episodes.map { episode in
            let shielded = shield && !episode.isWatched
            return TVDetailMapping.episode(episode, status: model.status(for: episode, shielded: shielded, highlights: highlightKeys), shielded: shielded)
        }
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
            episodesHeader: TVSectionHeader(
                title: model.selectedSeasonTitle,
                secondaryText: episodesState == .loaded ? (model.essentials.flatMap { EssentialsCopy.seasonDetail($0, season: model.episodes) } ?? Self.episodeCount(episodes.count)) : nil
            ),
            episodes: episodeCards,
            showsEpisodes: model.selectedSeason != nil,
            episodesState: episodesState,
            cast: TVDetailMapping.people(MovieDetailModel(item: model.show).castAndCrew),
            related: relatedCards,
            scores: scores
        ))
    }

    /// Asks Seerr whether the show is missing seasons nobody asked for, which adds Request More Seasons; the page never waits.
    private func loadRequestState() {
        guard SeerrAccount.shared.isConnected, let show = model?.show else { return }
        Task { [weak self] in
            guard let self else { return }
            let state = try? await SeerrTitles.shared.state(for: show, api: env.api)
            let offers = state?.canRequest(with: SeerrAccount.shared.permissions) ?? false
            guard offers != offersRequest else { return }
            offersRequest = offers
            rebuild()
        }
    }

    /// Fetches the ratings strip in the background; the page never waits for Trakt.
    private func loadScores() {
        Task { [weak self] in
            guard let self else { return }
            let found = await TraktScores.shared.scores(ratingKey: showKey, api: env.api)
            guard found != scores else { return }
            scores = found
            rebuild()
        }
    }

    /// Asks the paired Crucible Server for a Previously On, saying it is being written meanwhile.
    private func showPreviouslyOn() {
        guard let model, presentedViewController == nil else { return }
        let waiting = UIAlertController(title: CompanionCopy.previouslyOnTitle(model.show.title), message: CompanionCopy.writing, preferredStyle: .alert)
        let task = Task { [weak self, weak waiting] in
            let text: String
            do throws(CompanionError) {
                let (recap, server) = try await PreviouslyOnRequest.recap(model)
                text = "\(recap.text)\n\n\(CompanionCopy.basis(recap, server: server))"
            } catch {
                text = error.message
            }
            guard !Task.isCancelled, let waiting else { return }
            waiting.dismiss(animated: TVMotion.animationsEnabled) {
                self?.present(TVSynopsisViewController(title: CompanionCopy.previouslyOnTitle(model.show.title), text: text), animated: TVMotion.animationsEnabled)
            }
        }
        waiting.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in task.cancel() })
        present(waiting, animated: TVMotion.animationsEnabled)
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
        if PreviouslyOnRequest.isAvailable(model) {
            actions.append(TVDetailAction(kind: .previouslyOn, title: CompanionCopy.previouslyOn, symbol: "text.quote", handler: { [weak self] in self?.showPreviouslyOn() }))
        }
        if let plan = model.essentials, EssentialsCopy.shouldOffer(plan) {
            let preview = plan.preview(EssentialsChoice(level: .skipAnimeOnly))
            actions.append(TVDetailAction(
                kind: .essentialsOffer,
                title: String(localized: "Skip \(preview.hidden) Anime-Only · Save \(EssentialsCopy.duration(preview.seconds))", comment: "Apple TV button that turns on Skip Anime-Only, e.g. Skip 21 Anime-Only · Save 8 h 6 min"),
                symbol: "sparkles",
                accessibilityLabel: EssentialsCopy.offerTitle(plan, show: model.show.title) + " " + EssentialsCopy.offerMessage(plan),
                handler: { [weak self] in self?.answerOffer() }
            ))
        }
        actions.append(TVDetailAction(
            kind: .essentials,
            title: model.essentials.map(EssentialsCopy.barTitle) ?? (highlightsOnly ? Highlights.title : EssentialsLevel.all.title),
            symbol: "line.3.horizontal.decrease",
            menu: essentialsMenu(for: model),
            accessibilityLabel: String(localized: "Episodes: \(model.essentials.map(EssentialsCopy.barTitle) ?? EssentialsLevel.all.title)", comment: "VoiceOver label of the Essentials button, e.g. Episodes: Skip Anime-Only")
        ))
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
        if offersRequest {
            actions.append(TVDetailAction(kind: .request, title: SeerrCopy.requestMore, symbol: "plus.rectangle.on.rectangle", handler: { [weak self] in
                guard let self else { return }
                TVSeerrRequestViewController.open(show, env: env, isOnServer: true, from: self)
            }))
        }
        actions.append(TVDetailAction(
            kind: .playlist,
            title: PlaylistFormat.addToPlaylist,
            symbol: "text.badge.plus",
            handler: { [weak self] in
                guard let self else { return }
                TVPlaylistPicker.present(adding: [show], env: env, from: self)
            }
        ))
        if let manage = TVManageMenus.itemMenu(for: show, env: env, host: self, leavesScreenWhenDeleted: true, reload: { [weak self] in self?.reload() }) {
            actions.append(TVDetailAction(kind: .manage, title: ManageCopy.menuTitle, symbol: "wrench.and.screwdriver", menu: manage))
        }
        return actions
    }

    private func essentialsMenu(for model: ShowDetailModel) -> UIMenu {
        var sections: [UIMenuElement] = []
        if let plan = model.essentials {
            sections.append(UIMenu(options: .displayInline, children: EssentialsLevel.allCases.map { level in
                let action = UIAction(title: level.title, state: plan.choice.level == level ? .on : .off) { [weak self] _ in
                    var choice = plan.choice
                    choice.level = level
                    choice.offered = true
                    self?.saveEssentials(choice)
                }
                action.subtitle = EssentialsCopy.levelSubtitle(plan, level: level)
                return action
            }))
            var toggles: [UIMenuElement] = []
            if let range = plan.guide.ranges.first {
                let retold = UIAction(title: EssentialsCopy.retoldTitle(range), image: UIImage(systemName: "film"), state: plan.choice.seenRetold ? .on : .off) { [weak self] _ in
                    var choice = plan.choice
                    choice.seenRetold.toggle()
                    choice.offered = true
                    self?.saveEssentials(choice)
                }
                retold.subtitle = EssentialsCopy.retoldSubtitle(range)
                toggles.append(retold)
            }
            if !plan.hiddenKeys.isEmpty {
                toggles.append(UIAction(title: EssentialsCopy.showSkipped, image: UIImage(systemName: "eye"), state: showsSkipped ? .on : .off) { [weak self] _ in
                    self?.showsSkipped.toggle()
                    self?.rebuild()
                })
            }
            if !toggles.isEmpty { sections.append(UIMenu(options: .displayInline, children: toggles)) }
        } else if !model.highlightKeys.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: [false, true].map { highlights in
                let action = UIAction(title: highlights ? Highlights.title : EssentialsLevel.all.title, state: highlightsOnly == highlights ? .on : .off) { [weak self] _ in
                    self?.highlightsOnly = highlights
                    self?.rebuild()
                }
                action.subtitle = highlights ? Highlights.subtitle : nil
                return action
            }))
        }
        let shield = UIAction(title: SpoilerShield.title, image: UIImage(systemName: "eye.slash"), state: SpoilerShield.isOn(showKey) ? .on : .off) { [weak self] _ in
            guard let self else { return }
            SpoilerShield.set(showKey, on: !SpoilerShield.isOn(showKey))
            rebuild()
        }
        shield.subtitle = SpoilerShield.subtitle
        sections.append(UIMenu(options: .displayInline, children: [shield]))
        let title = model.essentials.map { EssentialsCopy.title + " · " + EssentialsCopy.sourceLine($0.guide) } ?? EssentialsCopy.title
        return UIMenu(title: title, children: sections)
    }

    private func saveEssentials(_ choice: EssentialsChoice) {
        Task { [weak self] in
            guard let self else { return }
            let plan = await EssentialsCenter.shared.save(choice, showRatingKey: showKey)
            model = model?.replacingEssentials(plan)
            rebuild()
        }
    }

    private func answerOffer() {
        guard let plan = model?.essentials else { return }
        var choice = plan.choice
        choice.offered = true
        choice.level = .skipAnimeOnly
        saveEssentials(choice)
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
