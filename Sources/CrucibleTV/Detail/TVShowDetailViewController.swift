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
    private lazy var scores: [TraktScore] = TraktScores.shared.cached(ratingKey: showKey)
    private var offersRequest = false
    /// Seerr's answer about the show, asked for as soon as the show itself arrived.
    private var pendingRequestTask: Task<Bool, Never>?
    private lazy var seasonSlot = makeTaskSlot()
    private lazy var requestSlot = makeTaskSlot()
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
        let isFirst = model == nil
        let scoresTask = isFirst ? startScores() : nil
        pendingRequestTask = nil
        do {
            let loaded = try await ShowDetailLoader.load(
                api: env.api,
                showRatingKey: showKey,
                initialSeasonKey: initialSeasonKey,
                selectedSeasonKey: { [weak self] in self?.model?.selectedSeasonKey },
                onShow: { [weak self] show in
                    guard isFirst, let self else { return }
                    pendingRequestTask = startRequestState(for: show)
                }
            )
            guard let loaded else {
                if !hasContent { showUnavailable(DetailMessage.showUnavailable) }
                return
            }
            seasonSlot.cancel()
            loadingSeasonKey = nil
            let requestTask = pendingRequestTask
            async let settledScores = settle(scoresTask)
            async let settledRequest = settle(requestTask)
            let (scoresIn, requestIn) = await (settledScores, settledRequest)
            if let scoresIn { scores = scoresIn }
            if let requestIn { offersRequest = requestIn }
            model = loaded
            rating.loaded()
            rebuild()
            if scoresIn == nil, let scoresTask { finish(scoresTask) { $0.scores = $1 } }
            if requestIn == nil, let requestTask { finish(requestTask) { $0.offersRequest = $1 } }
            if !isFirst { loadRequestState() }
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
            header: TVDetailMapping.heroInfo(model.heroInfo(trakt: scores), progress: nil),
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
            related: relatedCards
        ))
    }

    /// Asks Seerr whether the show is missing seasons nobody asked for, which adds Request More Seasons; the page never waits.
    private func loadRequestState() {
        guard SeerrAccount.shared.isConnected, let show = model?.show else { return }
        requestSlot.run { [weak self] in
            guard let self else { return }
            let state = try? await SeerrTitles.shared.state(for: show, api: env.api)
            guard !Task.isCancelled else { return }
            let offers = state?.canRequest(with: SeerrAccount.shared.permissions) ?? false
            guard offers != offersRequest else { return }
            offersRequest = offers
            easeIn { self.rebuild() }
        }
    }

    /// Starts fetching Trakt's scores for the meta line alongside the page, when Trakt is connected and none are cached.
    private func startScores() -> Task<[TraktScore], Never>? {
        guard TraktAccount.shared.isConnected, scores.isEmpty else { return nil }
        let ratingKey = showKey, api = env.api
        return Task { await TraktScores.shared.scores(ratingKey: ratingKey, api: api) }
    }

    /// Starts asking Seerr about the show as soon as the show itself is known, while its seasons still load.
    private func startRequestState(for show: PlexMetadata) -> Task<Bool, Never>? {
        guard SeerrAccount.shared.isConnected else { return nil }
        let api = env.api
        return Task {
            guard let state = try? await SeerrTitles.shared.state(for: show, api: api) else { return false }
            return state.canRequest(with: SeerrAccount.shared.permissions)
        }
    }

    private func settle<Value: Sendable>(_ task: Task<Value, Never>?) async -> Value? {
        guard let task else { return nil }
        return await Settle.value(of: task, within: Settle.detailGrace)
    }

    /// What arrived after the page appeared eases in with one refresh.
    private func finish<Value: Sendable & Equatable>(_ task: Task<Value, Never>, apply: @escaping @MainActor (TVShowDetailViewController, Value) -> Void) {
        Task { [weak self] in
            let value = await task.value
            guard let self, !Task.isCancelled else { return }
            apply(self, value)
            easeIn { self.rebuild() }
        }
    }

    /// Shows the show's Previously On: the paired Crucible Server's, or without one the last finished episodes'
    /// descriptions, read as they are or written into one recap by Crucible's AI after saying what that sends.
    private func showPreviouslyOn() {
        guard let model, presentedViewController == nil else { return }
        guard PreviouslyOnRequest.offer(model) == .descriptions else {
            showServerPreviouslyOn(model)
            return
        }
        let episodes = DescribedRecap.episodes(of: model)
        let title = CompanionCopy.previouslyOnTitle(model.show.title)
        guard HostedBrain.isAvailable else {
            present(TVSynopsisViewController(title: title, text: Self.descriptions(episodes)), animated: TVMotion.animationsEnabled)
            return
        }
        let choice = UIAlertController(title: title, message: DescribedRecapCopy.sends, preferredStyle: .alert)
        choice.addAction(UIAlertAction(title: DescribedRecapCopy.write, style: .default) { [weak self] _ in
            ProAccess.shared.requestUnlock(.previouslyOn) { unlocked in
                guard unlocked else { return }
                self?.writeRecap(model, episodes: episodes)
            }
        })
        choice.addAction(UIAlertAction(title: DescribedRecapCopy.readDescriptions, style: .default) { [weak self] _ in
            self?.present(TVSynopsisViewController(title: title, text: Self.descriptions(episodes)), animated: TVMotion.animationsEnabled)
        })
        choice.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(choice, animated: TVMotion.animationsEnabled)
    }

    /// The finished episodes as Plex describes them, with what Crucible Server would add.
    private static func descriptions(_ episodes: [DescribedEpisode]) -> String {
        let blocks = episodes.map { episode in
            (episode.code == episode.title ? episode.title : "\(episode.code) · \(episode.title)") + "\n" + episode.description
        }
        return (blocks + [DescribedRecapCopy.withServer]).joined(separator: "\n\n")
    }

    /// Has Crucible's AI write the descriptions into one recap, saying so meanwhile.
    private func writeRecap(_ model: ShowDetailModel, episodes: [DescribedEpisode]) {
        guard presentedViewController == nil else { return }
        let title = CompanionCopy.previouslyOnTitle(model.show.title)
        let waiting = UIAlertController(title: title, message: DescribedRecapCopy.writing, preferredStyle: .alert)
        let task = Task { [weak self, weak waiting] in
            let text: String
            do throws(HostedBrainError) {
                let recap = try await DescribedRecap.write(show: model.show.title, episodes: episodes)
                text = "\(recap)\n\n\(DescribedRecap.basis(episodes))"
            } catch {
                text = "\(DescribedRecapCopy.failure(error))\n\n\(Self.descriptions(episodes))"
            }
            guard !Task.isCancelled, let waiting else { return }
            waiting.dismiss(animated: TVMotion.animationsEnabled) {
                self?.present(TVSynopsisViewController(title: title, text: text), animated: TVMotion.animationsEnabled)
            }
        }
        waiting.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in task.cancel() })
        present(waiting, animated: TVMotion.animationsEnabled)
    }

    /// Asks the paired Crucible Server for a Previously On, saying it is being written meanwhile.
    private func showServerPreviouslyOn(_ model: ShowDetailModel) {
        guard presentedViewController == nil else { return }
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
        if PreviouslyOnRequest.offer(model) != .none {
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
