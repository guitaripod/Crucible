import CrucibleUI
import Foundation
import Kiln

/// The Search screen's genre tiles, cast without photos as monograms, the brand marks of the score services, the crystal
/// glyph, the alphabet rail and the Couch letter grid.
@MainActor
final class GalleryTiles: View {
    let genresTitle = SectionTitleView(title: "Browse Genres")
    let genres = GradientTileGridView()
    let cast = ShelfView(header: SectionHeader(title: "Cast Without Photos"), style: .person)
    let marksTitle = SectionTitleView(title: "Brand Marks")
    let marks: [BrandMarkView]
    let glyph = CrystalGlyphView()
    let rail = AlphabetRailView()
    let letters = LetterGridView()
    let page = PageView()
    private let markRow = SpacerView(height: 0)

    static let genrePairs: [(String, UInt32, UInt32)] = [
        ("Action", 0x7A2A1A, 0xE0643A), ("Adventure", 0x7A5A14, 0xE7B53A), ("Drama", 0x2A2A66, 0x6A6AE0), ("Sci-Fi", 0x0E4A52, 0x2FB8C4),
        ("Comedy", 0x2F4A1F, 0x8FC04A), ("Animation", 0x5A1F5A, 0xD05AB8), ("Thriller", 0x1F3A5A, 0x4A90D9), ("Mystery", 0x1A4A3A, 0x3AD08F),
    ]

    static let castGradients: [(String, String, UInt32, UInt32)] = [
        ("Ada Lindqvist", "AL", 0x2B2455, 0xB0483F), ("Marco Bellini", "MB", 0x0F3D3E, 0x1D7A73), ("Noor Haddad", "NH", 0x3A1A52, 0x8B2F7A),
        ("Kenji Mori", "KM", 0x101A33, 0x1F3F7A), ("Elsa Varga", "EV", 0x26402C, 0x4F7A45), ("Tomás Reyes", "TR", 0x6B2A3A, 0x7E3346),
    ]

    static let markNames = ["imdb", "rottentomatoes-fresh", "rottentomatoes-rotten", "metacritic", "letterboxd-dark", "tmdb", "trakt",
                            "myanimelist", "seerr"]

    override init(frame: Rect = .zero) {
        marks = Self.markNames.map(BrandMarkView.init)
        super.init(frame: frame)
        addSubview(page)
        marks.forEach(addSubview)
        [glyph, rail, letters].forEach(addSubview)
        genres.setTiles(Self.genrePairs.prefix(3).map { .init(id: $0.0, title: $0.0, top: Color(hex: $0.2), bottom: Color(hex: $0.1)) })
        cast.setItems(Self.castGradients.enumerated().map { index, person in
            var card = CardItem(id: "cast.\(index)", title: person.0, subtitle: ["Director", "Captain Vale", "Writer", "Mara", "Composer", "Ines"][index],
                                placeholderSymbol: "person")
            card.monogram = CardItem.Monogram(initials: person.1, top: Color(hex: person.2), bottom: Color(hex: person.3))
            return card
        })
        rail.update(letters: ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init))
        rail.currentLetter = "M"
        page.topInset = Theme.current.metrics.tv(40)
        page.setSections([genresTitle, genres, cast, marksTitle, markRow])
    }

    override var preferredFocusView: View? { genres }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let railWidth = AlphabetRailView.width
        page.frame = Rect(x: 0, y: 0, width: frame.width - railWidth - metrics.tv(24), height: frame.height * 0.72)
        markRow.height = metrics.tv(120)
        page.layoutIfNeeded()
        let markSide = metrics.tv(88)
        var x = metrics.sideMargin
        let y = markRow.frame.minY + metrics.tv(8) - page.contentOffset.y
        for mark in marks {
            mark.frame = Rect(x: x, y: y, width: markSide * 1.6, height: markSide)
            x += markSide * 1.6 + metrics.tv(28)
        }
        rail.frame = Rect(x: frame.width - railWidth - metrics.tv(12), y: metrics.tv(40), width: railWidth, height: frame.height - metrics.tv(80))
        let gridTop = frame.height * 0.72 + metrics.tv(12)
        let glyphSide = frame.height - gridTop - metrics.tv(24)
        glyph.frame = Rect(x: metrics.sideMargin, y: gridTop, width: glyphSide, height: glyphSide)
        let gridLeft = glyph.frame.maxX + metrics.tv(48)
        let gridWidth = page.frame.width - gridLeft - metrics.sideMargin
        letters.frame = Rect(x: gridLeft, y: gridTop, width: gridWidth, height: letters.sizeThatFits(Size(width: gridWidth, height: 0)).height)
    }
}

/// Text entry and quiet chrome: a search field with text, an empty one, a multi-line editor, status lines, a tooltip and
/// the title page's loading skeleton. Alerts, the rating panel and the shortcuts sheet are presented over it in captures.
@MainActor
final class GalleryPanels: View {
    let field = TextFieldView(placeholder: "Search movies, shows and people")
    let emptyField = TextFieldView(placeholder: "Server address", symbol: "server.rack")
    let editor = TextEditorView(placeholder: "Describe what you feel like watching")
    let status = StatusLineView()
    let failure = StatusLineView()
    let tooltip = TooltipView(text: "Mark Watched")
    let skeleton = DetailSkeletonView()
    let actions: [ButtonView] = [
        ButtonView(style: .glass, title: "Rate", symbol: "star"),
        ButtonView(style: .glass, title: "Rename", symbol: "pencil"),
        ButtonView(style: .glass, title: "Shortcuts", symbol: "keyboard"),
    ]

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [skeleton, field, emptyField, editor, status, failure, tooltip].forEach(addSubview)
        actions.forEach(addSubview)
        field.setText("salt fla", notify: false)
        editor.setText("Something slow and coastal,\nunder two hours, that I haven't seen.", notify: false)
        status.show("Connecting to Midgar…", busy: true)
        failure.show("Midgar didn't answer at 192.168.1.20:32400.", tone: .error)
        skeleton.show()
    }

    override var preferredFocusView: View? { field }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let half = frame.width / 2
        skeleton.frame = Rect(x: half, y: 0, width: half, height: frame.height)
        let width = half - metrics.sideMargin * 2
        var y = metrics.tv(60)
        for view in [field, emptyField] {
            let height = view.sizeThatFits(Size(width: width, height: 0)).height
            view.frame = Rect(x: metrics.sideMargin, y: y, width: width, height: height)
            y += height + metrics.tv(24)
        }
        editor.frame = Rect(x: metrics.sideMargin, y: y, width: width, height: metrics.tv(220))
        y = editor.frame.maxY + metrics.tv(40)
        for line in [status, failure] {
            let height = line.sizeThatFits(Size(width: width, height: 0)).height
            line.frame = Rect(x: metrics.sideMargin, y: y, width: width, height: height)
            y += height + metrics.tv(20)
        }
        var x = metrics.sideMargin
        y += metrics.tv(20)
        for button in actions {
            let size = button.sizeThatFits(.zero)
            button.frame = Rect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + metrics.tv(24)
        }
        let tip = tooltip.sizeThatFits(.zero)
        tooltip.frame = Rect(x: actions[0].frame.midX - tip.width / 2, y: actions[0].frame.maxY + metrics.tv(16), width: tip.width, height: tip.height)
    }

    /// The rename alert with its field, as a playlist rename shows it.
    func renameAlert() -> AlertView {
        AlertView(title: "Rename Playlist", message: "Choose a name for this playlist.", actions: [
            .init("Cancel", role: .cancel), .init("Rename"),
        ], fieldPlaceholder: "Name", fieldText: "Rainy Sundays")
    }

    func ratingPanel() -> RatingPanelView {
        RatingPanelView(title: "Rate Salt Flats", halfStars: 7, clearTitle: "Clear Rating")
    }

    func shortcuts() -> ShortcutsPanel {
        ShortcutsPanel(title: "Keyboard Shortcuts", groups: [
            .init("Go", shortcuts: [.init("Home", keys: ["Ctrl", "1"]), .init("Search", keys: ["Ctrl", "F"]), .init("Back", keys: ["Alt", "←"])]),
            .init("View", shortcuts: [.init("Larger Posters", keys: ["Ctrl", "+"]), .init("Full Screen", keys: ["F11"])]),
            .init("Player", shortcuts: [.init("Play or Pause", keys: ["Space"]), .init("Skip Intro", keys: ["S"]), .init("Mute", keys: ["M"])]),
        ])
    }
}

/// The Statistics components with fixture numbers: the ember hero, KPI tiles, the activity heat map, when you watch,
/// momentum, libraries, taste, binges, Wrapped moments and the You screen's Year in Review card.
@MainActor
final class GalleryStats: View {
    let hero = StatsHeroView()
    let tiles: [StatTileView] = (0..<3).map { _ in StatTileView() }
    let heatmap = ContributionHeatmapView()
    let clock = RadialClockView()
    let weekdays = WeekdayChartView()
    let trend = TrendAreaView()
    let libraries = LibrariesBreakdownView()
    let taste = TasteView()
    let yearCard = YearInReviewCardView()
    let binges = PanelShelfView(title: "Binges & Streaks", height: BingeCardView.height)
    let moments = PanelShelfView(title: "Wrapped Moments", height: Theme.current.metrics.tv(380))
    let page = PageView()
    private(set) var panels: [StatsPanelView] = []

    /// A year of fixture heat levels, one a day, in a pattern with streaks and gaps.
    static let levels: [Int] = {
        let pattern: [Int] = [0, 1, 3, 0, 2, 5, 4, 1, 0, 3]
        var levels: [Int] = []
        for day in 0..<(53 * 7) {
            let index: Int = (day * 37 + (day / 5) * 11 + (day / 9) * 3) % pattern.count
            levels.append(pattern[index])
        }
        return levels
    }()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(page)
        let levels = Self.levels
        hero.configure(eyebrow: "2026 so far", value: 467, unit: "hours", detail: "19 movies · 466 episodes · 5-day streak", since: "Since Jan 1",
                       stripLevels: Array(levels.suffix(28)), animate: false)
        let tileData: [(String, String, Symbol, String, [Int])] = [
            ("Plays", "547", "play.fill", "+12% on last year", [3, 5, 4, 7, 6, 9, 8]),
            ("Days Active", "189", "calendar", "52% of the year", [1, 2, 2, 3, 2, 4, 3]),
            ("Longest Streak", "13 days", "flame.fill", "Mar 2 to Mar 14", [0, 1, 4, 9, 13, 2, 1]),
        ]
        for (tile, data) in zip(tiles, tileData) {
            tile.configure(title: data.0, value: data.1, symbol: data.2, caption: data.3, sparkline: data.4, animate: false)
        }
        heatmap.configure(columns: 53, lastDayIndex: 53 * 7 - 3, cells: levels.enumerated().compactMap { day, level in
            level == 0 ? nil : ContributionHeatmapView.Cell(column: day / 7, row: day % 7, level: level)
        }, monthLabels: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].enumerated().map { (column: $0 * 53 / 12, text: $1) },
           animate: false)
        clock.configure(hours: [2, 1, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 4, 3, 3, 4, 6, 8, 12, 16, 18, 14, 9, 5], animate: false)
        weekdays.configure(values: [14, 6, 7, 8, 9, 15, 18], initials: ["S", "M", "T", "W", "T", "F", "S"],
                           counts: ["14", "6", "7", "8", "9", "15", "18"], animate: false)
        trend.configure(values: [3, 4, 6, 5, 8, 7, 9, 12, 10, 14, 13, 16], peakText: "Peak: November", animate: false)
        libraries.configure(slices: [
            .init(title: "TV Shows", value: 310, valueText: "310 h", colorIndex: 0), .init(title: "Movies", value: 112, valueText: "112 h", colorIndex: 1),
            .init(title: "Anime", value: 38, valueText: "38 h", colorIndex: 2), .init(title: "Documentaries", value: 7, valueText: "7 h", colorIndex: 3),
        ], centerTitle: "467 h", centerSubtitle: "4 libraries", animate: false)
        taste.show(rows: [
            .init(title: "Drama", valueText: "38%", fraction: 0.38, colorIndex: 0), .init(title: "Thriller", valueText: "22%", fraction: 0.22, colorIndex: 1),
            .init(title: "Mystery", valueText: "17%", fraction: 0.17, colorIndex: 2), .init(title: "Sci-Fi", valueText: "11%", fraction: 0.11, colorIndex: 3),
        ])
        yearCard.configure(caption: "2026 so far", primary: "467", unit: "hours", detail: "19 movies · 466 episodes · 5-day streak", strip: Array(levels.suffix(84)))
        binges.setPanels([("The Salt Road", 9, "Ended Nov 2"), ("Meridian", 6, "Ended Oct 18"), ("Ironwood", 5, "Ended Sep 30")].enumerated().map { index, binge in
            StatsPanelView(content: BingeCardView(title: binge.0, episodes: binge.1, countText: "\(binge.1) eps", caption: binge.2, colorIndex: index), flush: true)
        })
        moments.setPanels([("calendar", "80", "Busiest Day", "80 plays on Nov 15"), ("flame.fill", "13", "Longest Streak", "days in a row"),
                           ("tv.fill", "57", "Biggest Binge", "57 episodes of The Salt Road")].map { moment in
            StatsPanelView(content: SuperlativeCardView(symbol: Symbol(moment.0), headline: moment.1, title: moment.2, caption: moment.3), flush: true)
        })
        let clockRow = GalleryRow([clock, weekdays])
        panels = [
            StatsPanelView(title: "Activity", accessory: StatsHeatLegendView(), content: heatmap),
            StatsPanelView(title: "When You Watch", content: clockRow),
            StatsPanelView(title: "Your Momentum", content: trend),
            StatsPanelView(title: "Your Libraries", content: libraries),
            StatsPanelView(title: "Your Taste", content: taste),
        ]
        let tileRow = GalleryRow(tiles.map { StatsPanelView(content: $0, flush: true) })
        page.topInset = Theme.current.metrics.tv(40)
        page.setSections([GalleryInset(hero), GalleryInset(tileRow)] + panels.map { GalleryInset($0) } + [binges, moments, GalleryInset(yearCard)])
    }

    override var preferredFocusView: View? { page }

    override func layoutSubviews() {
        page.frame = bounds
    }
}

/// Views side by side with the gutter between them, as tall as the tallest.
@MainActor
final class GalleryRow: View {
    private let items: [View]

    init(_ items: [View]) {
        self.items = items
        super.init()
        items.forEach(addSubview)
    }

    override var preferredFocusView: View? { items.first }

    private func itemWidth(_ width: Float) -> Float {
        let gutter = Theme.current.metrics.gutter
        return ((width - gutter * Float(items.count - 1)) / Float(max(items.count, 1))).rounded(.down)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let width = itemWidth(size.width)
        return Size(width: size.width, height: items.map { $0.sizeThatFits(Size(width: width, height: 0)).height }.max() ?? 0)
    }

    override func layoutSubviews() {
        let width = itemWidth(frame.width)
        for (index, item) in items.enumerated() {
            item.frame = Rect(x: Float(index) * (width + Theme.current.metrics.gutter), y: 0, width: width, height: frame.height)
        }
    }
}

/// A section inset to the side margins with room below it, as the Statistics page sets its panels.
@MainActor
final class GalleryInset: View {
    private let child: View

    init(_ child: View) {
        self.child = child
        super.init()
        addSubview(child)
    }

    override var preferredFocusView: View? { child }

    private var margin: Float { Theme.current.metrics.sideMargin }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: child.sizeThatFits(Size(width: size.width - margin * 2, height: 0)).height + Theme.current.metrics.tv(44))
    }

    override func layoutSubviews() {
        let height = child.sizeThatFits(Size(width: frame.width - margin * 2, height: 0)).height
        child.frame = Rect(x: margin, y: 0, width: frame.width - margin * 2, height: height)
    }
}
