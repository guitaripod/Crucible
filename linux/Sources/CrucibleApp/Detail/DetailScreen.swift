import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The shared body of the movie, episode and show pages (`TVDetailViewController`): the backdrop, the hero over it, the
/// synopsis with More, the action row and the sections below. It loads every time it appears, so a page shows the new
/// progress after playback; a refresh while the page is on screen updates it in place.
@MainActor
class DetailScreen: ScreenView {
    let api: APIClient
    let backdrop = BackdropView()
    let hero = HeroInfoView()
    let page = PageView()
    let heroRoom = SpacerView(height: 0)
    let synopsis = SynopsisView(text: "")
    let actions = DetailActionRow()
    let information = InformationView()
    let state = StateView()
    private let skeleton = DetailSkeletonView()
    private(set) var hasContent = false
    /// The title's Trakt community, after Cast & Crew.
    lazy var community = CommunitySection(api: api, host: self)
    private var loadTask: Task<Void, Never>?
    private var synopsisTitle = ""

    /// The page for a title from a card: shows open the show page, everything else the movie or episode page.
    static func make(api: APIClient, item: PlexMetadata) -> DetailScreen {
        make(api: api, route: .related(item), placeholder: item)
    }

    static func make(api: APIClient, route: DetailRoute, placeholder: PlexMetadata? = nil) -> DetailScreen {
        let screen: DetailScreen = switch route {
        case .show(let ratingKey, let season):
            ShowDetailScreen(api: api, ratingKey: ratingKey, initialSeasonKey: season, placeholder: placeholder)
        case .item(let ratingKey, _, let showKey, let seasonKey):
            MediaDetailScreen(api: api, ratingKey: ratingKey, showRatingKey: showKey, seasonRatingKey: seasonKey, placeholder: placeholder)
        }
        screen.route = route
        return screen
    }

    /// The title this page shows, which a relaunch reopens (`WindowRestoration`).
    private(set) var route: DetailRoute?

    init(api: APIClient, placeholder: PlexMetadata?) {
        self.api = api
        super.init()
        [backdrop, hero, page, state, skeleton].forEach(addSubview)
        skeleton.isHidden = true
        page.onScroll = { [weak self] offset in
            guard let self else { return }
            self.hero.translation = Point(x: 0, y: -offset)
            self.backdrop.dimming = min(max(offset / max(self.heroRoom.height * 0.8, 1), 0), 1)
            self.rootView?.contentScrolled(offset: offset)
        }
        synopsis.onMore = { [weak self] in self?.presentSynopsis() }
        community.onConnected = { [weak self] in self?.reload() }
        state.isHidden = true
        if let placeholder {
            hero.configure(HeroInfo(title: placeholder.title), animated: false)
            let art = placeholder.art ?? placeholder.grandparentArt
            backdrop.show(art.map { .path($0, .backdrop) }, immediate: true)
            page.setSections([heroRoom, actions])
        } else {
            showLoading()
        }
    }

    override var preferredFocusView: View? { !skeleton.isHidden ? skeleton : state.isHidden ? actions : state }
    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        reload()
        community.start()
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
        community.stop()
    }

    /// Loads the title; subclasses fetch and then call `present`.
    func fetch() async {}

    /// The Play/Pause key anywhere on the page a focused card did not take: subclasses play the page's title.
    func playFromKey() {}

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.key == .mediaPlay || event.key == .mediaPause, hasContent else { return super.keyPressed(event) }
        playFromKey()
        return true
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.fetch() }
    }

    /// Puts the loaded page on screen: hero, artwork, synopsis, actions, then `sections`.
    func present(hero info: HeroInfo, artwork: DetailArtwork, synopsis text: String?, synopsisTitle: String, actions list: [DetailAction],
                 sections: [View]) {
        hasContent = true
        state.isHidden = true
        page.isHidden = false
        hero.isHidden = false
        hero.configure(info, animated: true)
        revealFromSkeleton()
        if let path = artwork.path { backdrop.show(.path(path, artwork.isBackdrop ? .backdrop : .poster), immediate: true) }
        self.synopsisTitle = synopsisTitle
        actions.setActions(list)
        var all: [View] = [heroRoom]
        if let text, !text.isEmpty {
            synopsis.text = text
            all.append(synopsis)
        }
        all.append(actions)
        all.append(contentsOf: sections)
        page.setSections(all)
        setNeedsLayout()
    }

    /// The skeleton holds the screen while nothing of the title is known.
    func showLoading() {
        hasContent = false
        let hadFocus = containsFocus
        skeleton.show()
        if hadFocus { window?.focus.focus(skeleton, animated: false) }
        page.isHidden = true
        state.isHidden = true
    }

    /// The first page fades in under the skeleton, taking the focus it held to the actions.
    private func revealFromSkeleton() {
        guard !skeleton.isHidden else { return }
        if skeleton.containsFocus { window?.focus.focus(actions, animated: false) }
        skeleton.fadeOut()
    }

    /// A title that is gone or cannot be shown, with Go Back.
    func showUnavailable(_ message: String) {
        hasContent = false
        skeleton.isHidden = true
        page.isHidden = true
        hero.isHidden = true
        state.isHidden = false
        state.show(.empty(title: String(localized: "Not Available"), message: message, symbol: "questionmark.circle",
                          action: StateView.Action(title: String(localized: "Go Back")) { [weak self] in _ = self?.navigation?.pop() }))
        window?.focus.focus(state, animated: false)
    }

    func showFailure(title: String, message: String) {
        hasContent = false
        skeleton.isHidden = true
        page.isHidden = true
        hero.isHidden = true
        state.isHidden = false
        state.show(.error(title: title, message: message, retryTitle: String(localized: "Retry", comment: "Button that retries loading the screen"),
                          retry: { [weak self] in
                              self?.showLoading()
                              self?.reload()
                          }))
        window?.focus.focus(state, animated: false)
    }

    /// Playback Settings for a show, a movie or an episode's show: how it skips, plays on and matches the screen its own
    /// way, and what the player remembered for it (`TitleRulesScreen`).
    func playbackSettingsAction(for item: PlexMetadata) -> DetailAction? {
        let isShow = item.mediaType == "show" || item.mediaType == "episode"
        guard isShow || item.mediaType == "movie" else { return nil }
        let ratingKey = item.mediaType == "episode" ? item.grandparentRatingKey : item.id
        guard let ratingKey else { return nil }
        let name = item.mediaType == "episode" ? item.grandparentTitle ?? item.title : item.title
        return DetailAction(id: "playbackSettings", title: TitleRulesCopy.pageTitle, symbol: "slider.horizontal.3", behaviour: .run { [weak self] in
            self?.rootView?.push(TitleRulesScreen(ratingKey: ratingKey, name: name, isShow: isShow))
        })
    }

    /// The owner's Manage button for `item`, last in the action row; deleting the title leaves its page.
    func manageAction(for item: PlexMetadata) -> DetailAction? {
        guard ManageTools.offers(item) else { return nil }
        let tools = ManageTools.itemMenu(for: item, api: api, host: self, leavesScreenWhenDeleted: true) { [weak self] in self?.reload() }
        return DetailAction(id: "manage", title: ManageCopy.menuTitle, symbol: "wrench.and.screwdriver",
                            behaviour: .menu(title: ManageCopy.menuTitle, items: tools.items, choose: tools.choose))
    }

    /// Marking a title as one the app cannot play here, which leaves it out of Home, search and the libraries on every
    /// device of the server, or putting it back (`IncompatibleTitles`).
    func incompatibleAction(for item: PlexMetadata) -> DetailAction {
        let marked = IncompatibleTitles.hides(item)
        return DetailAction(
            id: "incompatible",
            title: marked ? IncompatibleCopy.unmark : IncompatibleCopy.mark,
            symbol: marked ? "eye" : "eye.slash",
            behaviour: .run { [weak self] in self?.toggleIncompatible(item, marked: marked) }
        )
    }

    private func toggleIncompatible(_ item: PlexMetadata, marked: Bool) {
        Task { [weak self, api] in
            guard let self else { return }
            if marked, let mark = IncompatibleTitles.marks.first(where: { $0.ratingKey == item.id }) {
                do {
                    try await IncompatibleTitles.unmark(mark, api: api)
                } catch {
                    alert(IncompatibleCopy.unmark, message: ConnectionError.message(for: error))
                    return
                }
            } else {
                await IncompatibleTitles.markManually(item, api: api)
            }
            reload()
        }
    }

    func alert(_ title: String, message: String? = nil) {
        guard let window else { return }
        AlertView.notice(title: title, message: message, in: window)
    }

    /// Fetches Trakt's scores for the hero's meta line alongside the page, when Trakt is connected and `cached` is empty, and
    /// hands them to `arrived` once there are some.
    func fetchScores(ratingKey: String, cached: [TraktScore], arrived: @escaping @MainActor ([TraktScore]) -> Void) {
        guard TraktAccount.shared.isConnected, cached.isEmpty else { return }
        let api = api
        Task {
            let scores = await TraktScores.shared.scores(ratingKey: ratingKey, api: api)
            guard !scores.isEmpty else { return }
            arrived(scores)
        }
    }

    /// The Check In action (Cancel Check-In while checked in to this title) for a movie or episode, while Trakt is connected
    /// and allowed to send changes (`TVMediaDetailViewController`).
    func checkInAction(for item: PlexMetadata, done: @escaping @MainActor () -> Void) -> DetailAction? {
        guard TraktAccount.shared.isConnected, TraktAccount.shared.choices.sendsChanges else { return nil }
        let checkedIn = TraktCheckin.isCheckedIn(to: item.id)
        return DetailAction(id: "checkIn", title: checkedIn ? TraktCopy.cancelCheckIn : TraktCopy.checkIn,
                            symbol: checkedIn ? "mappin.slash" : "mappin.and.ellipse",
                            behaviour: .run { [weak self] in self?.checkIn(ratingKey: item.id, durationSecs: item.durationSecs, done: done) })
    }

    /// Checks in to `ratingKey` on Trakt, or cancels the check-in already on it, offering to replace a check-in to something
    /// else still running (`TVDetailNavigation.checkIn`).
    private func checkIn(ratingKey: String, durationSecs: Double?, replacing: Bool = false, done: @escaping @MainActor () -> Void) {
        let api = api
        Task { [weak self] in
            do {
                if TraktCheckin.isCheckedIn(to: ratingKey), !replacing {
                    try await TraktCheckin.cancel()
                    self?.alert(TraktCopy.checkInCancelled)
                    done()
                    return
                }
                if replacing { try await TraktCheckin.cancel() }
                switch try await TraktCheckin.checkIn(ratingKey: ratingKey, durationSecs: durationSecs, api: api) {
                case .checkedIn:
                    self?.alert(TraktCopy.checkedIn)
                    done()
                case .notMatched:
                    self?.alert(TraktCopy.checkIn, message: TraktCopy.checkInNotMatched)
                case .alreadyWatching(let until):
                    self?.offerReplacingCheckIn(until: until) { [weak self] in
                        self?.checkIn(ratingKey: ratingKey, durationSecs: durationSecs, replacing: true, done: done)
                    }
                }
            } catch {
                MidgarLog.error("Trakt check-in failed ratingKey=\(ratingKey): \(error)", category: .trakt)
                self?.alert(TraktCopy.checkIn, message: ConnectionError.message(for: error))
            }
        }
    }

    /// Asks whether to replace the check-in to something else that runs until `until`.
    private func offerReplacingCheckIn(until: Date?, replace: @escaping () -> Void) {
        guard let window else { return }
        let time = until.map { $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Formatters.displayLocale)) }
        AlertView.confirm(title: TraktCopy.checkIn, message: TraktCopy.alreadyCheckedIn(until: time), confirm: TraktCopy.replaceCheckIn,
                          in: window, action: replace)
    }

    private func presentSynopsis() {
        guard let window else { return }
        AlertView(title: synopsisTitle, message: synopsis.text, actions: [AlertView.Action(String(localized: "Close"), role: .cancel)]).present(in: window)
    }

    func push(_ route: DetailRoute) {
        rootView?.push(DetailScreen.make(api: api, route: route))
    }

    /// A cast or crew card's right click or menu key: Copy Name.
    func presentPersonMenu(_ card: CardItem, at point: Point?) {
        guard let window, !card.title.isEmpty else { return }
        let frame = window.focusedView?.frameInWindow ?? frameInWindow
        let anchor = Rect(x: point.map { $0.x } ?? frame.minX, y: point.map { $0.y } ?? frame.maxY, width: 1, height: 1)
        let menu = MenuView(title: card.title, items: [.init(id: "copy", title: String(localized: "Copy Name"), symbol: "doc.on.doc")], anchor: anchor)
        menu.onSelect = { [weak window] _ in window?.copy(card.title) }
        menu.present(in: window)
    }

    /// The page sits over the hero, which shows through its top: a point on the hero's text there goes to the hero, so the
    /// title can be selected.
    override func hitTest(_ point: Point) -> View? {
        let hit = super.hitTest(point)
        guard hit === page, !hero.isHidden else { return hit }
        return hero.hitTest(hero.convert(point, from: self)) ?? hit
    }

    /// A cast or crew member's titles in the libraries (`TVScreens.filmography`).
    func openPerson(_ person: PlexRole) {
        let api = api
        let grid = TitleGridScreen(api: api, title: person.tag ?? "", empty: .init(
            symbol: "person.crop.rectangle.stack",
            title: String(localized: "Nothing in Your Libraries"),
            message: String(localized: "None of this person’s titles are on your server.")
        )) { try await PersonFilmography.titles(of: person, api: api) }
        rootView?.push(grid)
    }

    /// The collection a title's tag names, found by name in its library (`TVScreens.openCollection`).
    func openCollection(named name: String, sectionId: String?) {
        guard let sectionId else { return }
        let api = api
        Task { [weak self] in
            do {
                guard let collection = try await CollectionsFeed.collection(named: name, inSection: sectionId, api: api) else {
                    self?.alert(name, message: String(localized: "This collection is no longer on the server."))
                    return
                }
                let grid = TitleGridScreen(api: api, title: collection.title, empty: .init(
                    symbol: "rectangle.stack", title: String(localized: "Empty Collection"), message: String(localized: "This collection has no titles.")
                )) { try await CollectionsFeed.items(inCollection: collection.id, api: api) }
                self?.rootView?.push(grid)
            } catch {
                self?.alert(String(localized: "Couldn’t Load"), message: ConnectionError.message(for: error))
            }
        }
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        backdrop.frame = bounds
        page.frame = bounds
        state.frame = bounds
        skeleton.frame = bounds
        let heroHeight = Theme.current.density == .desk ? max(metrics.heroHeight, frame.height * 0.36) : max(metrics.heroHeight, frame.height * 0.5)
        heroRoom.height = heroHeight
        hero.frame = Rect(x: metrics.sideMargin, y: metrics.heroTopClearance, width: frame.width - metrics.sideMargin * 2,
                          height: heroHeight - metrics.heroTopClearance - metrics.heroBottomClearance)
        page.setNeedsLayout()
    }
}

/// Core's detail values in the design system's terms.
@MainActor
enum DetailMapping {
    static func hero(_ info: DetailHeroInfo, progress: Double?) -> HeroInfo {
        HeroInfo(eyebrow: info.eyebrow, title: info.title, metaParts: info.meta.leading, ratings: info.meta.ratings.map(rating),
                 badges: info.badges, progress: progress, titleStyle: .title1, spokenText: info.accessibilityText)
    }

    /// A score under its source's mark, as `RatingLine` draws it: Rotten Tomatoes' rotten splat below 60%, Letterboxd's
    /// dots in the appearance's colour.
    static func rating(_ rating: DetailRating) -> HeroRating {
        switch rating.mark {
        case .none: return HeroRating(mark: nil, text: rating.text, spoken: rating.spoken)
        case .star: return HeroRating(mark: .star, text: rating.text, spoken: rating.spoken)
        case .score(let score):
            let mark: HeroRating.Mark
            switch score.source {
            case .trakt: mark = .brand("trakt", isWordmark: false)
            case .imdb: mark = .brand("imdb", isWordmark: true)
            case .tmdb: mark = .brand("tmdb", isWordmark: true)
            case .rottenTomatoes: mark = .brand(score.value >= 60 ? "rottentomatoes-fresh" : "rottentomatoes-rotten", isWordmark: false)
            case .metascore: mark = .brand("metacritic", isWordmark: false)
            case .letterboxd: mark = .brand(Theme.current.palette.appearance == .dark ? "letterboxd-dark" : "letterboxd-light", isWordmark: false)
            case .myAnimeList: mark = .brand("myanimelist", isWordmark: true)
            }
            return HeroRating(mark: mark, text: rating.text, spoken: rating.spoken)
        }
    }

    static func person(_ role: PlexRole, index: Int) -> CardItem {
        let name = role.tag ?? ""
        var card = CardItem(id: "cast.\(index)", artwork: role.thumb.flatMap(URL.init(string:)).map { .url($0) }, title: name, subtitle: role.role,
                            placeholderSymbol: "person")
        let gradient = CastAvatar.gradient(for: name)
        card.monogram = CardItem.Monogram(initials: DetailFormat.initials(name), top: Color(hex: gradient.start), bottom: Color(hex: gradient.end))
        return card
    }

    static func related(_ items: [PlexMetadata]) -> [CardItem] {
        items.map { item in
            var card = TitleCards.card(item)
            card.id = "related.\(item.id)"
            return card
        }
    }

    static func facts(_ facts: [DetailFact], genres: [String]) -> [(key: String, value: String)] {
        var all = facts.map { (key: $0.key, value: $0.value) }
        if !genres.isEmpty { all.insert((key: String(localized: "Genres"), value: genres.joined(separator: ", ")), at: 0) }
        return all
    }
}

extension DetailScreen: Reloadable {}
