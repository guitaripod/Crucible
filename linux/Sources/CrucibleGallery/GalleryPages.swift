import CrucibleUI
import Foundation
import Kiln

/// Fixture content, the same titles the Apple TV gallery shows.
@MainActor
enum GalleryFixtures {
    struct Feature {
        let card: CardItem
        let hero: HeroInfo
        let backdrop: URL
    }

    static func feature(_ id: String, title: String, subtitle: String, progress: Double?, eyebrow: String, meta: [String], badges: [String],
                        synopsis: String) -> Feature {
        let backdrop = GalleryArt.url("backdrop", id)
        return Feature(
            card: CardItem(id: id, artwork: .url(backdrop), title: title, subtitle: subtitle,
                           detail: progress.map { _ in subtitle }, progress: progress, placeholderSymbol: "film"),
            hero: HeroInfo(eyebrow: eyebrow, title: title, metaParts: meta, badges: badges, synopsis: synopsis, progress: progress),
            backdrop: backdrop
        )
    }

    static let continueWatching: [Feature] = [
        feature("salt-flats", title: "Salt Flats", subtitle: "1h 12m left", progress: 0.38, eyebrow: "Continue Watching",
                meta: ["2024", "PG-13", "1h 58m", "★ 7.4"], badges: ["4K", "Dolby Vision", "Atmos"],
                synopsis: "Two surveyors cross the world's brightest desert to map a lake that is no longer there, and discover who has been moving the horizon."),
        feature("the-last-lighthouse", title: "The Last Lighthouse", subtitle: "S1 · E4 · 38m left", progress: 0.62, eyebrow: "Continue Watching",
                meta: ["S1 · E4", "TV-14", "52m"], badges: ["HDR10", "5.1"],
                synopsis: "The keeper's final winter on the rock begins with a radio call that should be impossible, and ends with a decision that cannot be undone."),
        feature("winter-orchard", title: "Winter Orchard", subtitle: "21m left", progress: 0.81, eyebrow: "Continue Watching",
                meta: ["2023", "PG", "1h 41m", "★ 8.1"], badges: ["4K", "Atmos"],
                synopsis: "A family returns to the orchard they sold, a week before the first frost, to settle who gets to harvest the last of the trees."),
        feature("neon-tides", title: "Neon Tides", subtitle: "S2 · E7", progress: 0.12, eyebrow: "Up Next",
                meta: ["S2 · E7", "TV-MA", "47m"], badges: ["Dolby Vision"],
                synopsis: "The harbour district wakes up to a power cut that is not a power cut, and the night shift has to decide whom to trust."),
        feature("ember-run", title: "Ember Run", subtitle: "Movie", progress: nil, eyebrow: "Recently Added",
                meta: ["2025", "R", "2h 04m", "★ 6.9"], badges: ["4K", "HDR10"],
                synopsis: "A courier with one night and a car that should not start crosses a city that is burning in all the wrong places."),
    ]

    static func poster(_ title: String, _ subtitle: String, unwatched: Bool = false, progress: Double? = nil, watched: Bool = false,
                       badge: String? = nil) -> CardItem {
        let seed = title.lowercased().replacingOccurrences(of: " ", with: "-")
        return CardItem(id: seed, artwork: .url(GalleryArt.url("poster", seed)), title: title, subtitle: subtitle, progress: progress,
                        isUnwatched: unwatched, isWatched: watched, badgeText: badge)
    }

    static let posters: [CardItem] = [
        poster("Salt Flats", "2024", unwatched: true),
        poster("The Last Lighthouse", "2 Seasons", progress: 0.62),
        poster("Winter Orchard", "2023", watched: true),
        poster("Neon Tides", "3 Seasons", unwatched: true, badge: "NEW"),
        poster("Ember Run", "2025"),
        poster("Paper Moons", "2022", watched: true),
        poster("Quiet Harbor", "2021"),
        poster("Glass City", "2024", unwatched: true),
        poster("Hollow Crown", "1 Season"),
        poster("Northern Lines", "2020"),
        poster("Saltwater Kings", "4 Seasons", unwatched: true),
        poster("The Long Field", "2019"),
    ]

    static let people: [CardItem] = ["Ada Lindqvist", "Marco Bellini", "Noor Haddad", "Kenji Mori", "Elsa Varga", "Tomás Reyes", "Ines Kowal"]
        .enumerated().map { index, name in
            CardItem(id: "person-\(index)", artwork: .url(GalleryArt.url("person", name.lowercased())), title: name,
                     subtitle: ["Director", "Mara", "Lt. Okafor", "The Keeper", "Writer", "Jonas", "Composer"][index], placeholderSymbol: "person")
        }

    static let episodes: [CardItem] = [
        CardItem(id: "ep1", artwork: .url(GalleryArt.url("backdrop", "orchard-ep1")), title: "1  ·  The First Frost", subtitle: "46m",
                 isWatched: true, isDimmed: true, placeholderSymbol: "tv"),
        CardItem(id: "ep2", artwork: .url(GalleryArt.url("backdrop", "orchard-ep2")), title: "2  ·  What the Bees Know", subtitle: "52m",
                 detail: "28m left", eyebrow: "Continue", progress: 0.45, placeholderSymbol: "tv"),
        CardItem(id: "ep3", artwork: .url(GalleryArt.url("backdrop", "orchard-ep3")), title: "3  ·  A Ladder Against the Sky", subtitle: "49m",
                 eyebrow: "Up Next", isUnwatched: true, placeholderSymbol: "tv"),
        CardItem(id: "ep4", artwork: .url(GalleryArt.url("backdrop", "orchard-ep4")), title: "4  ·  Windfall", subtitle: "51m", isUnwatched: true,
                 placeholderSymbol: "tv"),
        CardItem(id: "ep5", artwork: nil, title: "5  ·  Cider", subtitle: "44m", isUnwatched: true, placeholderSymbol: "tv"),
    ]

    /// Every fixture URL and the title its poster carries.
    static var allArt: [URL: String?] {
        var urls: [URL: String?] = [:]
        for feature in continueWatching { urls[feature.backdrop] = .some(nil) }
        for poster in posters {
            if case .url(let url) = poster.artwork { urls[url] = poster.title }
        }
        for item in people + episodes {
            if case .url(let url) = item.artwork { urls[url] = .some(nil) }
        }
        let untitled: String? = nil
        for seed in ["lighthouse", "salt-flats", "neon", "ember"] {
            urls[GalleryArt.url("backdrop", seed)] = untitled
        }
        return urls
    }
}

/// The Home screen of the Apple TV app with fixture content: backdrop following focus, hero, shelves, the glass tab bar.
@MainActor
final class GalleryHome: View {
    let backdrop = BackdropView()
    let hero = HeroInfoView()
    let page = PageView()
    let tabBar = TabBarView()
    let continueShelf: ShelfView
    let postersShelf: ShelfView
    let peopleShelf: ShelfView
    private let heroRoom = SpacerView(height: 0)

    override init(frame: Rect = .zero) {
        continueShelf = ShelfView(header: SectionHeader(title: "Continue Watching"), style: .landscape)
        postersShelf = ShelfView(header: SectionHeader(title: "Recently Added Movies", secondaryText: "12 new", hasSeeAll: true), style: .poster)
        peopleShelf = ShelfView(header: SectionHeader(title: "Cast & Crew"), style: .person)
        super.init(frame: frame)
        addSubview(backdrop)
        addSubview(hero)
        addSubview(page)
        addSubview(tabBar)
        continueShelf.setItems(GalleryFixtures.continueWatching.map(\.card))
        postersShelf.setItems(GalleryFixtures.posters)
        peopleShelf.setItems(GalleryFixtures.people)
        page.setSections([heroRoom, continueShelf, postersShelf, peopleShelf])
        tabBar.tabs = [
            .init(id: "home", title: "Home"), .init(id: "movies", title: "Movies"), .init(id: "shows", title: "TV Shows"),
            .init(id: "search", title: "Search"), .init(id: "you", title: "You"),
        ]
        tabBar.select("home", animated: false)
        continueShelf.onFocus = { [weak self] item in self?.feature(item.id, animated: true) }
        page.onScroll = { [weak self] offset in
            guard let self else { return }
            self.hero.translation = Point(x: 0, y: -offset)
            self.backdrop.dimming = min(max(offset / max(self.heroRoom.height, 1), 0), 1)
            self.tabBar.setHidden(offset > Theme.current.metrics.tv(40), animated: true)
        }
        feature(GalleryFixtures.continueWatching[0].card.id, animated: false)
    }

    func feature(_ id: String, animated: Bool) {
        guard let feature = GalleryFixtures.continueWatching.first(where: { $0.card.id == id }) else { return }
        hero.configure(feature.hero, animated: animated)
        backdrop.show(.url(feature.backdrop), immediate: !animated)
    }

    override var preferredFocusView: View? { continueShelf }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        backdrop.frame = bounds
        page.frame = bounds
        tabBar.frame = Rect(x: 0, y: 0, width: frame.width, height: metrics.tabBarTop + metrics.tabBarHeight + metrics.tv(20))
        let heroHeight = max(metrics.heroHeight, min(frame.height * 0.52, frame.width * 0.3))
        heroRoom.height = heroHeight
        hero.frame = Rect(x: metrics.sideMargin, y: metrics.heroTopClearance, width: frame.width - metrics.sideMargin * 2,
                          height: heroHeight - metrics.heroTopClearance - metrics.heroBottomClearance)
        page.setNeedsLayout()
    }
}

/// Every card state side by side: rest, focused, hovered, progress, watched, unwatched, badge, placeholder, dimmed.
@MainActor
final class GalleryCards: View {
    let posters = ShelfView(header: SectionHeader(title: "Posters"), style: .poster)
    let episodes = ShelfView(header: SectionHeader(title: "Episodes"), style: .episode)
    let people = ShelfView(header: SectionHeader(title: "People"), style: .person)
    let page = PageView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(page)
        posters.setItems(Array(GalleryFixtures.posters.prefix(8)) + [CardItem(id: "missing", title: "No Artwork", subtitle: "Placeholder")])
        episodes.setItems(GalleryFixtures.episodes)
        people.setItems(GalleryFixtures.people)
        page.topInset = Theme.current.metrics.tv(40)
        page.setSections([posters, episodes, people])
    }

    override func layoutSubviews() {
        page.frame = bounds
    }
}

/// Buttons and chips over a dark and a bright backdrop, at rest, focused and pressed.
@MainActor
final class GalleryControls: View {
    let dark = ArtworkView()
    let bright = ArtworkView()
    let rows: [[ButtonView]]
    let chips = ChipRowView()
    let chipsBright = ChipRowView()

    override init(frame: Rect = .zero) {
        func row() -> [ButtonView] {
            [
                ButtonView(style: .primary, title: "Play", symbol: "play.fill"),
                ButtonView(style: .glass, title: "Trailer", symbol: "film"),
                ButtonView(style: .glass, title: nil, symbol: "plus"),
                ButtonView(style: .glass, title: "Audio", symbol: "waveform"),
                ButtonView(style: .plain, title: "See All", symbol: "chevron.right", symbolTrailing: true),
            ]
        }
        rows = [row(), row()]
        super.init(frame: frame)
        addSubview(dark)
        addSubview(bright)
        for row in rows { for button in row { addSubview(button) } }
        let chipItems: [ChipRowView.Chip] = [
            .init(id: "all", title: "All", isSelected: true), .init(id: "unwatched", title: "Unwatched"),
            .init(id: "4k", title: "4K", symbol: "sparkles"), .init(id: "s3", title: "Season 3", isDimmed: true),
            .init(id: "genre", title: "Genre", symbol: "line.3.horizontal.decrease"),
        ]
        chips.setChips(chipItems)
        chipsBright.setChips(chipItems)
        addSubview(chips)
        addSubview(chipsBright)
    }

    func show() {
        dark.source = .url(GalleryArt.url("backdrop", "lighthouse"))
        bright.source = .url(GalleryArt.url("backdrop", "salt-flats"))
    }

    override func didMoveToWindow() { show() }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let half = frame.height / 2
        dark.frame = Rect(x: 0, y: 0, width: frame.width, height: half)
        bright.frame = Rect(x: 0, y: half, width: frame.width, height: half)
        for (index, row) in rows.enumerated() {
            var x = metrics.sideMargin
            let y = Float(index) * half + metrics.tv(120)
            for button in row {
                let size = button.sizeThatFits(Size(width: 600, height: 200))
                button.frame = Rect(x: x, y: y + (metrics.primaryControlHeight - size.height) / 2, width: size.width, height: size.height)
                x += size.width + metrics.tv(32)
            }
        }
        let chipHeight = chips.sizeThatFits(bounds.size).height
        chips.frame = Rect(x: 0, y: metrics.tv(260), width: frame.width, height: chipHeight)
        chipsBright.frame = Rect(x: 0, y: half + metrics.tv(260), width: frame.width, height: chipHeight)
    }
}

/// A library grid with its filter chips.
@MainActor
final class GalleryGrid: View {
    let chips = ChipRowView()
    let grid = CardGridView()
    let page = PageView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(page)
        chips.setChips([
            .init(id: "all", title: "All", isSelected: true), .init(id: "unwatched", title: "Unwatched"), .init(id: "recent", title: "Recently Added"),
        ])
        grid.setItems(GalleryFixtures.posters + GalleryFixtures.posters.map {
            var copy = $0
            copy.id += "-2"
            return copy
        })
        page.topInset = Theme.current.metrics.tabBarClearance - Theme.current.metrics.tv(40)
        page.setSections([chips, grid])
    }

    override func layoutSubviews() {
        page.frame = bounds
    }
}

/// A pushed screen's title over settings rows, and the loading, empty and error states beside a loading skeleton.
@MainActor
final class GalleryStates: View {
    let title = ScreenTitleView(title: "Settings", summary: "Crucible 3.0", detail: "Everything here applies to this computer.")
    let rows = RowListView()
    let loading = StateView()
    let empty = StateView()
    let failed = StateView()
    let skeleton = SkeletonShelfView(style: .poster)

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [title, rows, loading, empty, failed, skeleton].forEach(addSubview)
        rows.columnWidth = Theme.current.metrics.tv(1100)
        rows.setItems([
            RowItem(id: "server", title: "Server", subtitle: "Midgar · 3 libraries", value: "Connected", symbol: "server.rack", accessory: .chevron),
            RowItem(id: "quality", title: "Streaming Quality", value: "Original", symbol: "dial.high", accessory: .chevron),
            RowItem(id: "match", title: "Match Content", subtitle: "Switch the display to the video's frame rate and range", value: "On",
                    symbol: "tv"),
            RowItem(id: "lang", title: "Subtitles", symbol: "captions.bubble", accessory: .checkmark),
            RowItem(id: "signout", title: "Sign Out", symbol: "rectangle.portrait.and.arrow.right", isDestructive: true),
        ])
        rows.onSelect = { _ in }
        loading.show(.loading(title: "Loading Library"))
        empty.show(.empty(title: "Nothing Here Yet", message: "Movies you add to your watchlist show up here.", symbol: "bookmark",
                          action: StateView.Action(title: "Browse Movies") {}))
        failed.show(.error(title: "Couldn't Load Home", message: "The server didn't answer. Check that it's running.", retryTitle: "Try Again",
                           retry: {}, secondary: StateView.Action(title: "Switch Server") {}))
    }

    override var preferredFocusView: View? { rows }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let titleHeight = title.sizeThatFits(bounds.size).height
        title.frame = Rect(x: 0, y: metrics.tv(60), width: frame.width / 2, height: titleHeight)
        let rowsHeight = rows.sizeThatFits(Size(width: frame.width / 2, height: 0)).height
        rows.frame = Rect(x: 0, y: title.frame.maxY + metrics.tv(24), width: frame.width / 2, height: rowsHeight)
        let skeletonHeight = skeleton.sizeThatFits(bounds.size).height
        skeleton.frame = Rect(x: 0, y: max(rows.frame.maxY + metrics.tv(24), frame.height - skeletonHeight), width: frame.width / 2,
                              height: skeletonHeight)
        let column = Size(width: frame.width / 2, height: frame.height)
        let heights = [loading, empty, failed].map { $0.sizeThatFits(column).height }
        let gap = max((frame.height - heights.reduce(0, +)) / 4, metrics.tv(24))
        var y = gap
        for (state, height) in zip([loading, empty, failed], heights) {
            state.frame = Rect(x: frame.width / 2, y: y, width: frame.width / 2, height: height)
            y += height + gap
        }
    }
}
