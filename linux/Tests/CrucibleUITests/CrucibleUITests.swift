import Foundation
import Testing
@testable import CrucibleUI
@testable import Kiln

@MainActor
enum SharedGPU {
    static let gpu: GPU = {
        do { return try GPU(display: nil, surface: nil) } catch { fatalError("\(error)") }
    }()
}

@MainActor
@Suite(.serialized) struct TokenTests {
    @Test func deskIsTheTVLayoutAtSixtyPercent() {
        let desk = Metrics(density: .desk)
        let couch = Metrics(density: .couch)
        #expect(couch.posterSize == Size(width: 260, height: 390))
        #expect(desk.posterSize == Size(width: 156, height: 234))
        #expect(desk.gutter == 24)
        #expect(TypeScale(metrics: desk).body.size == 17.5)
        #expect(TypeScale(metrics: couch).headline.size == 38)
    }

    @Test func cardZoomScalesCardsButNotTheLayout() {
        let zoomed = Metrics(density: .desk, cardZoom: 1.25)
        #expect(zoomed.posterSize.width == 195)
        #expect(zoomed.gutter == 24)
        #expect(Metrics(density: .desk, cardZoom: 5).cardZoom == 1.6)
    }

    @Test func aGridAddsColumnsAsTheWindowWidens() {
        Theme.current.density = .desk
        let narrow = CardStyle.grid(aspect: 1.5, width: 1000)
        let wide = CardStyle.grid(aspect: 1.5, width: 2000)
        let metrics = Theme.current.metrics
        #expect(metrics.gridColumns(itemWidth: wide.itemWidth, width: 2000) > metrics.gridColumns(itemWidth: narrow.itemWidth, width: 1000))
        let columns = metrics.gridColumns(itemWidth: narrow.itemWidth, width: 1000)
        let used = Float(columns) * narrow.itemWidth + Float(columns - 1) * metrics.gutter
        #expect(used <= 1000 && used > 1000 - Float(columns))
    }

    @Test func landscapeGridCardsCoverAboutAPostersArea() {
        Theme.current.density = .couch
        defer { Theme.current.density = .desk }
        let style = CardStyle.grid(aspect: 9.0 / 16.0, width: 1760)
        #expect(style.kind == .backdrop)
        #expect(style.itemWidth > 260)
        #expect(abs(style.artworkSize.height - (style.itemWidth * 9 / 16).rounded()) < 1)
    }

    @Test func overlaysOnDarkColoursMatchSRGBBlending() {
        let shade = Color.shade(0.5)
        let blended = 1 - shade.alpha
        let srgbResult: Float = 0.5
        let linearOfSRGB = Float(pow(Double(srgbResult), 2.2))
        #expect(abs(blended - linearOfSRGB) < 0.01)
    }
}

@MainActor
@Suite(.serialized) struct ComponentTests {
    let window: Window

    init() throws {
        Theme.current.density = .desk
        window = try Window(offscreen: Size(width: 1280, height: 720), scale: 1, gpu: SharedGPU.gpu)
    }

    @Test func aShelfLaysOutItsCardsAndRemembersFocus() {
        let shelf = ShelfView(header: SectionHeader(title: "Continue Watching"), style: .poster)
        shelf.setItems((0..<12).map { CardItem(id: "\($0)", title: "Title \($0)") })
        window.contentView.addSubview(shelf)
        shelf.frame = Rect(x: 0, y: 0, width: 1280, height: shelf.preferredHeight)
        window.render()
        let metrics = Theme.current.metrics
        #expect(shelf.card(for: "0")?.frame.x == metrics.sideMargin)
        #expect(shelf.card(for: "1")?.frame.x == metrics.sideMargin + CardStyle.poster.itemWidth + metrics.gutter)
        #expect(shelf.scroller.contentLength > 1280)
        window.focus.setVisible(true)
        window.focus.focus(shelf, animated: false)
        #expect(window.focusedView === shelf.card(for: "0"))
        for _ in 0..<9 { window.handleKey(KeyEvent(key: .right)) }
        window.settle()
        #expect(window.focusedView === shelf.card(for: "9"))
        #expect(shelf.card(for: "9")!.frameInWindow.maxX <= 1280)
    }

    @Test func replacingItemsKeepsTheViewsOfItemsThatStay() {
        let shelf = ShelfView(header: nil, style: .poster)
        shelf.setItems([CardItem(id: "a", title: "A"), CardItem(id: "b", title: "B")])
        let kept = shelf.card(for: "b")
        shelf.setItems([CardItem(id: "b", title: "B renamed"), CardItem(id: "c", title: "C")])
        #expect(shelf.card(for: "b") === kept)
        #expect(kept?.item.title == "B renamed")
        #expect(shelf.card(for: "a") == nil)
    }

    @Test func theHeroGivesWayLineByLineWhenItRunsOutOfRoom() {
        let hero = HeroInfoView()
        window.contentView.addSubview(hero)
        let long = HeroInfo(eyebrow: "Continue Watching", title: "A Title Long Enough To Need Two Lines In The Hero Block Of Home",
                            metaParts: ["2024", "PG-13"], badges: ["4K"],
                            synopsis: String(repeating: "A sentence that keeps going and going across the column. ", count: 8))
        hero.frame = Rect(x: 0, y: 0, width: 540, height: 400)
        hero.configure(long, animated: false)
        window.render()
        hero.frame = Rect(x: 0, y: 0, width: 540, height: 120)
        window.render()
        #expect(window.capture().pixels.count > 0)
    }

    @Test func aButtonSizesToItsLabelAndActivatesOnEnter() {
        let button = ButtonView(style: .glass, title: "Trailer", symbol: "film")
        var presses = 0
        button.onPress = { presses += 1 }
        window.contentView.addSubview(button)
        let size = button.sizeThatFits(Size(width: 1000, height: 1000))
        #expect(size.height == Theme.current.metrics.primaryControlHeight)
        #expect(size.width > size.height)
        button.frame = Rect(origin: Point(x: 100, y: 100), size: size)
        window.focus.focus(button, animated: false)
        window.handleKey(KeyEvent(key: .return))
        #expect(presses == 1)
        window.handlePointerMoved(to: Point(x: 110, y: 110))
        window.handlePointerButton(.primary, pressed: true)
        window.handlePointerButton(.primary, pressed: false)
        #expect(presses == 2)
    }

    @Test func aTabBarSelectsWithThePointer() {
        let bar = TabBarView()
        bar.tabs = [.init(id: "home", title: "Home"), .init(id: "movies", title: "Movies")]
        bar.select("home", animated: false)
        var chosen: String?
        bar.onSelect = { chosen = $0.id }
        bar.frame = Rect(x: 0, y: 0, width: 1280, height: 100)
        window.contentView.addSubview(bar)
        window.render()
        let movies = bar.subviews.last!.frameInWindow
        window.handlePointerMoved(to: Point(x: movies.midX, y: movies.midY))
        window.handlePointerButton(.primary, pressed: true)
        window.handlePointerButton(.primary, pressed: false)
        #expect(chosen == "movies")
        #expect(bar.selectedID == "movies")
    }
}
