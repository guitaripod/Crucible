import Foundation
import Testing
@testable import Kiln

@MainActor
enum TestGPU {
    static let shared: GPU = {
        do { return try GPU(display: nil, surface: nil) } catch { fatalError("\(error)") }
    }()
}

@MainActor
final class Tile: View {
    let name: String
    var activations = 0
    var focusChanges: [Bool] = []

    init(_ name: String, frame: Rect) {
        self.name = name
        super.init(frame: frame)
    }

    override var canBecomeFocused: Bool { true }
    override func activate() { activations += 1 }
    override func focusDidChange(focused: Bool, animated: Bool) { focusChanges.append(focused) }
}

@MainActor
final class Row: View {
    override var remembersFocus: Bool { true }
}

@MainActor
final class Overlay: View {
    override var isFocusScope: Bool { true }
}

@MainActor
final class FocusWatcher: View {
    var moves: [String?] = []

    override func descendantFocusDidChange(to view: View?) {
        moves.append((view as? Tile)?.name)
    }
}

/// A focus scope that stacks its tiles only when laid out, as a menu places its rows.
@MainActor
final class StackedOverlay: View {
    override var isFocusScope: Bool { true }

    override func layoutSubviews() {
        for (index, tile) in subviews.enumerated() {
            tile.frame = Rect(x: 100, y: 100 + Float(index) * 60, width: 300, height: 50)
        }
    }
}

/// A disc at full coverage and a square at a quarter, side by side.
@MainActor
final class ShapeCanvas: View {
    override func draw(_ context: inout DrawContext) {
        var path = Path()
        path.ellipse(in: Rect(x: 10, y: 10, width: 80, height: 80))
        path.fill()
        path.move(to: Point(x: 120, y: 20))
        path.line(to: Point(x: 180, y: 20))
        path.line(to: Point(x: 180, y: 80))
        path.line(to: Point(x: 120, y: 80))
        path.close()
        path.fill(coverage: 0.25)
        context.shape(path, in: bounds, color: .white)
    }
}

/// A screen that prefers its loading tile while it shows, then its content.
@MainActor
final class LoadingScreen: View {
    let loading = Tile("loading", frame: Rect(x: 700, y: 400, width: 200, height: 100))
    let content = Row(frame: Rect(x: 0, y: 0, width: 1000, height: 600))

    override var preferredFocusView: View? { loading.isHidden ? content : loading }
}

@MainActor
final class Ticker: View {
    var ticks = 0

    override func advanceAnimations(_ dt: Float) -> Bool {
        ticks += 1
        return true
    }
}

@MainActor
@Suite(.serialized) struct FocusTests {
    let window: Window
    let root = View()

    init() throws {
        window = try Window(offscreen: Size(width: 1000, height: 600), gpu: TestGPU.shared)
        window.contentView = root
    }

    private func grid() -> [[Tile]] {
        (0..<3).map { row in
            let container = Row(frame: Rect(x: 0, y: Float(row) * 200, width: 1000, height: 180))
            root.addSubview(container)
            return (0..<4).map { column in
                let tile = Tile("\(row),\(column)", frame: Rect(x: 20 + Float(column) * 240, y: 0, width: 220, height: 180))
                container.addSubview(tile)
                return tile
            }
        }
    }

    @Test func arrowsMoveToTheNeighbourInThatDirection() {
        let tiles = grid()
        window.focus.focus(tiles[0][0], animated: false)
        window.handleKey(KeyEvent(key: .right))
        #expect(window.focusedView === tiles[0][0], "the first arrow after a click only shows focus")
        window.handleKey(KeyEvent(key: .right))
        #expect(window.focusedView === tiles[0][1])
        window.handleKey(KeyEvent(key: .down))
        #expect(window.focusedView === tiles[1][1])
        window.handleKey(KeyEvent(key: .left))
        #expect(window.focusedView === tiles[1][0])
        window.handleKey(KeyEvent(key: .left))
        #expect(window.focusedView === tiles[1][0], "nothing to the left keeps focus")
        window.handleKey(KeyEvent(key: .up))
        #expect(window.focusedView === tiles[0][1], "the first row remembers the tile focus left it from")
    }

    @Test func aRowRemembersTheTileFocusLeftFrom() {
        let tiles = grid()
        window.focus.setVisible(true)
        window.focus.focus(tiles[0][3], animated: false)
        window.handleKey(KeyEvent(key: .down))
        #expect(window.focusedView === tiles[1][3])
        window.handleKey(KeyEvent(key: .left))
        window.handleKey(KeyEvent(key: .left))
        #expect(window.focusedView === tiles[1][1])
        window.handleKey(KeyEvent(key: .up))
        #expect(window.focusedView === tiles[0][3], "back to where focus left the first row, not the nearest tile")
    }

    @Test func tabWalksReadingOrderAndWraps() {
        let tiles = grid()
        window.focus.focus(tiles[2][3], animated: false)
        window.handleKey(KeyEvent(key: .tab))
        #expect(window.focusedView === tiles[0][0])
        window.handleKey(KeyEvent(key: .leftTab, modifiers: .shift))
        #expect(window.focusedView === tiles[2][3])
        window.handleKey(KeyEvent(key: .leftTab, modifiers: .shift))
        #expect(window.focusedView === tiles[2][2])
    }

    @Test func enterActivatesAndFocusShowsOnlyAfterTheKeyboard() {
        let tiles = grid()
        window.focus.focus(tiles[0][0], animated: false)
        #expect(!window.isFocusVisible)
        window.handleKey(KeyEvent(key: .return))
        #expect(tiles[0][0].activations == 1)
        #expect(window.isFocusVisible)
        window.handlePointerMoved(to: Point(x: 500, y: 300))
        window.handlePointerButton(.primary, pressed: true)
        window.handlePointerButton(.primary, pressed: false)
        #expect(!window.isFocusVisible)
    }

    @Test func hoverNeverMovesFocus() {
        let tiles = grid()
        window.focus.focus(tiles[0][0], animated: false)
        window.handlePointerMoved(to: Point(x: 520, y: 290))
        #expect(tiles[1][2].isHovered)
        #expect(window.focusedView === tiles[0][0])
    }

    @Test func arrowsAndTabStayInsideAFocusScope() {
        let tiles = grid()
        let overlay = Overlay(frame: Rect(x: 300, y: 250, width: 400, height: 100))
        let first = Tile("a", frame: Rect(x: 0, y: 0, width: 180, height: 100))
        let second = Tile("b", frame: Rect(x: 220, y: 0, width: 180, height: 100))
        overlay.addSubview(first)
        overlay.addSubview(second)
        root.addSubview(overlay)
        window.focus.focus(first, animated: false)
        window.handleKey(KeyEvent(key: .up))
        window.handleKey(KeyEvent(key: .left))
        #expect(window.focusedView === first, "nothing outside the scope takes focus")
        window.handleKey(KeyEvent(key: .right))
        #expect(window.focusedView === second)
        window.handleKey(KeyEvent(key: .tab))
        #expect(window.focusedView === first, "Tab wraps within the scope")
        overlay.removeFromSuperview()
        window.focus.focus(tiles[0][0], animated: false)
        window.focus.setVisible(true)
        window.handleKey(KeyEvent(key: .down))
        #expect((window.focusedView as? Tile)?.name.hasPrefix("1,") == true, "with the scope gone, arrows reach the page again")
    }

    @Test func containersHearWhenTheFocusEntersOrLeavesThem() {
        let tiles = grid()
        let watcher = FocusWatcher(frame: Rect(x: 0, y: 620, width: 1000, height: 180))
        let inside = Tile("inside", frame: Rect(x: 20, y: 0, width: 220, height: 180))
        watcher.addSubview(inside)
        root.addSubview(watcher)
        window.focus.focus(tiles[0][0], animated: false)
        #expect(watcher.moves.isEmpty, "a move elsewhere is not reported")
        window.focus.focus(inside, animated: false)
        window.focus.focus(tiles[1][0], animated: false)
        #expect(watcher.moves == ["inside", "1,0"], "entering and leaving are each reported once")
    }

    @Test func removingTheFocusedViewMovesFocusToTheNearest() {
        let tiles = grid()
        window.focus.focus(tiles[1][1], animated: false)
        tiles[1][1].removeFromSuperview()
        let focused = window.focusedView as? Tile
        #expect(focused?.name == "1,0" || focused?.name == "1,2")
    }

    @Test func arrowsRightAfterAScopeOpensMoveThroughItsLaidOutRows() {
        let menu = StackedOverlay(frame: Rect(x: 0, y: 0, width: 1000, height: 600))
        let rows = (0..<3).map { Tile("row \($0)", frame: .zero) }
        rows.forEach(menu.addSubview)
        root.addSubview(menu)
        window.focus.setVisible(true)
        window.focus.focus(rows[0], animated: false)
        window.handleKey(KeyEvent(key: .down))
        window.handleKey(KeyEvent(key: .down))
        #expect((window.focusedView as? Tile)?.name == "row 2", "rows placed by the overlay's layout, before any frame drew")
    }

    @Test func hidingThePreferredLoadingViewHandsFocusToWhatTheScreenPrefersNext() {
        let screen = LoadingScreen(frame: Rect(x: 0, y: 0, width: 1000, height: 600))
        root.addSubview(screen)
        let first = Tile("first", frame: Rect(x: 20, y: 20, width: 200, height: 100))
        let nearLoading = Tile("near", frame: Rect(x: 700, y: 300, width: 200, height: 100))
        [first, nearLoading].forEach(screen.content.addSubview)
        screen.addSubview(screen.loading)
        window.focus.focus(screen, animated: false)
        #expect((window.focusedView as? Tile)?.name == "loading")
        screen.loading.isHidden = true
        #expect((window.focusedView as? Tile)?.name == "first", "the content's first tile, not the one nearest the spinner")
    }
}

@MainActor
@Suite(.serialized) struct ScrollTests {
    let window: Window
    let shelf = ScrollView(axis: .horizontal)
    var tiles: [Tile] = []

    init() throws {
        window = try Window(offscreen: Size(width: 1000, height: 400), gpu: TestGPU.shared)
        shelf.frame = Rect(x: 0, y: 100, width: 1000, height: 200)
        shelf.revealInsets = EdgeInsets(leading: 40, trailing: 40)
        for index in 0..<10 {
            let tile = Tile("\(index)", frame: Rect(x: 40 + Float(index) * 240, y: 0, width: 220, height: 200))
            shelf.addSubview(tile)
            tiles.append(tile)
        }
        shelf.contentLength = 40 + 10 * 240 + 20
        window.contentView.addSubview(shelf)
        window.render()
    }

    @Test func focusingAnOffscreenTileScrollsItIntoView() {
        window.focus.setVisible(true)
        window.focus.focus(tiles[0], animated: false)
        for _ in 0..<6 { window.handleKey(KeyEvent(key: .right)) }
        #expect(window.focusedView === tiles[6])
        window.settle()
        let frame = tiles[6].frameInWindow
        #expect(frame.maxX <= 1000 - 40 + 0.5)
        #expect(frame.minX >= 0)
        #expect(shelf.offset > 0)
    }

    @Test func aPointerRestingOnTheShelfLetsTheWindowGoIdle() {
        window.handlePointerMoved(to: Point(x: 500, y: 200))
        window.handleScroll(ScrollEvent(dx: 15, dy: 0, notchesX: 1, source: .wheel))
        window.advance(by: 2)
        #expect(!window.isAnimating, "the indicator stays up while hovered without drawing every frame")
        window.handlePointerMoved(to: Point(x: 500, y: 380))
        #expect(window.isAnimating, "leaving the shelf starts the indicator's fade")
        window.advance(by: 2)
        #expect(!window.isAnimating)
    }

    @Test func wheelNotchesGlideByASteppedDistanceAndStopAtTheEnd() {
        window.handlePointerMoved(to: Point(x: 500, y: 200))
        window.handleScroll(ScrollEvent(dx: 15, dy: 0, notchesX: 1, source: .wheel))
        window.settle()
        #expect(abs(shelf.offset - shelf.wheelStep) < 0.5)
        for _ in 0..<40 { window.handleScroll(ScrollEvent(dx: 15, dy: 0, notchesX: 1, source: .wheel)) }
        window.settle()
        #expect(abs(shelf.offset - shelf.maximumOffset) < 0.5)
    }

    @Test func aTouchpadFlingKeepsGoingAfterTheFingersLift() {
        window.handlePointerMoved(to: Point(x: 500, y: 200))
        for frame in 0..<6 {
            window.handleScroll(ScrollEvent(dx: 30, dy: 0, source: .finger, timeMilliseconds: UInt32(frame * 8)))
        }
        let atLift = shelf.offset
        #expect(abs(atLift - 180) < 0.5)
        window.handleScroll(ScrollEvent(dx: 0, dy: 0, source: .finger, ended: true, timeMilliseconds: 48))
        window.settle()
        #expect(shelf.offset > atLift + 100)
        #expect(shelf.offset <= shelf.maximumOffset)
    }

    @Test func draggingPastTheStartRubberBandsAndSpringsBack() {
        window.handlePointerMoved(to: Point(x: 500, y: 200))
        for frame in 0..<5 {
            window.handleScroll(ScrollEvent(dx: -40, dy: 0, source: .finger, timeMilliseconds: UInt32(frame * 8)))
        }
        #expect(shelf.offset < 0)
        #expect(shelf.offset > -200, "resistance keeps the overscroll well short of the drag")
        window.handleScroll(ScrollEvent(dx: 0, dy: 0, source: .finger, ended: true, timeMilliseconds: 40))
        window.settle()
        #expect(abs(shelf.offset) < 0.5)
    }

    @Test func verticalSwipesPassThroughAHorizontalShelf() {
        window.handlePointerMoved(to: Point(x: 500, y: 200))
        window.handleScroll(ScrollEvent(dx: 2, dy: 30, source: .finger))
        #expect(shelf.offset == 0)
    }
}

@MainActor
@Suite(.serialized) struct DrawingTests {
    @Test func aLabelDrawsCrispTextAtTheWindowScale() throws {
        let window = try Window(offscreen: Size(width: 400, height: 100), scale: 2, gpu: TestGPU.shared)
        window.background = .black
        let label = Label("Continue Watching", font: Font(size: 24, weight: .bold), color: .white)
        label.frame = Rect(x: 10, y: 10, width: 380, height: 40)
        window.contentView.addSubview(label)
        window.render()
        let capture = window.capture()
        #expect(capture.width == 800)
        let lit = stride(from: 0, to: capture.pixels.count, by: 4).filter { capture.pixels[$0] > 0.9 }.count
        #expect(lit > 4000)
        let size = label.sizeThatFits(Size(width: 380, height: 40))
        #expect(size.width > 150 && size.width < 300)
        #expect(size.height > 24 && size.height < 34)
    }

    @Test func aShapeFillsItsPathAndAddsEachPaintsCoverage() throws {
        let window = try Window(offscreen: Size(width: 200, height: 100), scale: 2, gpu: TestGPU.shared)
        window.background = .black
        let canvas = ShapeCanvas(frame: Rect(x: 0, y: 0, width: 200, height: 100))
        window.contentView.addSubview(canvas)
        window.render()
        let capture = window.capture()
        func red(_ x: Int, _ y: Int) -> Float { capture.pixels[(y * capture.width + x) * 4] }
        #expect(red(100, 100) > 0.95, "inside the full-coverage disc")
        #expect(red(4, 4) < 0.01, "outside it")
        #expect(red(300, 100) > 0.1 && red(300, 100) < 0.4, "a quarter-coverage square, in linear light")
    }

    @Test func everyMappedSymbolRendersAMask() {
        let symbols = SymbolRenderer(gpu: TestGPU.shared)
        var blank: [String] = []
        for name in SymbolRenderer.map.keys.sorted() {
            guard let texture = symbols.texture(for: Symbol(name), pixelSize: 48) else {
                blank.append(name)
                continue
            }
            let coverage = texture.download().enumerated().filter { $0.offset % 4 == 0 }.reduce(Float(0)) { $0 + $1.element }
            if coverage < 20 { blank.append(name) }
        }
        #expect(blank.isEmpty, "\(blank)")
        #expect(SymbolRenderer.map.count > 150)
    }

    @Test func aFilledBadgeSymbolCutsItsGlyphOutOfTheDisc() {
        let symbols = SymbolRenderer(gpu: TestGPU.shared)
        let filled = symbols.texture(for: "checkmark.circle.fill", pixelSize: 96)!.download()
        let outline = symbols.texture(for: "checkmark.circle", pixelSize: 96)!.download()
        func coverage(_ pixels: [Float]) -> Float { stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + pixels[$1] } }
        #expect(coverage(filled) > coverage(outline) * 2)
        #expect(filled[(20 * 96 + 48) * 4] > 0.9, "the disc is solid above the check")
        #expect(filled[(48 * 96 + 48) * 4] < 0.1, "the check is cut through it")
    }

    @Test func everySystemNameTheAppleTVScreensUseIsMapped() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sf-symbols-used.txt")
        var names = Set((try String(contentsOf: fixture, encoding: .utf8)).split(separator: "\n").map(String.init))
        let pattern = /systemName: "([a-z0-9.]+)"/
        for directory in ["CrucibleTV", "CrucibleCore", "CrucibleDesign"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for match in source.matches(of: pattern) { names.insert(String(match.1)) }
            }
        }
        let missing = names.filter { !SymbolRenderer.has(Symbol($0)) }.sorted()
        #expect(missing.isEmpty, "unmapped SF Symbols: \(missing)")
    }
}

@Suite struct ImageDecoderTests {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAEAQMAAACJA+yzAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURf8AAAAA/2yh/Y4AAAAHdElNRQfqCw8JFiqcSvSNAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTExLTE1VDA5OjIyOjQyKzAwOjAw+c7t/gAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMS0xNVQwOToyMjo0MiswMDowMIiTVUIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTEtMTVUMDk6MjI6NDIrMDA6MDDfhnSdAAAADElEQVQI12PgZwBDAAD4AD3ab+xIAAAAAElFTkSuQmCC")!
    static let webp = Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBIAAAAvB8AAAA8Q87//8x8O+hDR/wA=")!
    static let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAARCAAEAAgDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABgQAAIDAAAAAAAAAAAAAAAAAAAIRYTD/8QAFAEBAAAAAAAAAAAAAAAAAAAACP/EABgRAAIDAAAAAAAAAAAAAAAAAAAJRoTE/9oADAMBAAIRAxEAPwA0WqgbWIqFlyujsGowyM3ch//Z")!

    @Test(arguments: [("png", png), ("webp", webp), ("jpeg", jpeg)])
    func decodesRedThenBlue(_ format: String, _ data: Data) throws {
        let image = try ImageDecoder.decode(data)
        #expect(image.width == 8 && image.height == 4, "\(format)")
        let left = Array(image.pixels[(1 * 8 + 1) * 4..<(1 * 8 + 1) * 4 + 4])
        let right = Array(image.pixels[(1 * 8 + 6) * 4..<(1 * 8 + 6) * 4 + 4])
        #expect(left[0] > 200 && left[2] < 60 && left[3] == 255, "\(format) \(left)")
        #expect(right[2] > 200 && right[0] < 60, "\(format) \(right)")
    }

    @Test func garbageIsAnError() {
        #expect(throws: ImageError.self) { try ImageDecoder.decode(Data([1, 2, 3, 4, 5])) }
    }

    @Test func cacheNamesDifferForDifferentURLs() {
        let a = ImageStore.cacheName(for: URL(string: "https://plex.example/photo?width=260&url=/library/1")!)
        let b = ImageStore.cacheName(for: URL(string: "https://plex.example/photo?width=260&url=/library/2")!)
        #expect(a != b)
        #expect(a.count > 20)
    }
}

@MainActor
@Suite(.serialized) struct AnimationParkingTests {
    @Test func anAnimationUnderAHiddenViewRestsUntilItIsShownAgain() throws {
        let window = try Window(offscreen: Size(width: 200, height: 200), gpu: TestGPU.shared)
        let parent = View(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        let ticker = Ticker(frame: Rect(x: 0, y: 0, width: 50, height: 50))
        parent.addSubview(ticker)
        window.contentView.addSubview(parent)
        ticker.startAnimating()
        window.advance(by: 0.1)
        #expect(ticker.ticks > 0)
        parent.isHidden = true
        window.advance(by: 0.1)
        let resting = ticker.ticks
        window.advance(by: 0.1)
        #expect(!window.isAnimating)
        #expect(ticker.ticks == resting)
        parent.isHidden = false
        #expect(window.isAnimating)
        window.advance(by: 0.1)
        #expect(ticker.ticks > resting)
    }
}

@Suite struct AnimationTests {
    @Test func aSpringSettlesOnItsTarget() {
        var value = Animated(1)
        value.set(1.04, animation: .focus)
        var steps = 0
        while value.advance(1.0 / 120) { steps += 1 }
        #expect(value.value == 1.04)
        #expect(steps > 10 && steps < 120)
    }

    @Test func aTimedCurveTakesItsDuration() {
        var value = Animated(0)
        value.set(1, animation: .timed(duration: 0.25, curve: .easeInOut))
        value.advance(0.125)
        #expect(abs(value.value - 0.5) < 0.02)
        value.advance(0.13)
        #expect(value.value == 1)
        #expect(!value.isAnimating)
    }

    @Test func easeOutStartsFast() {
        #expect(Animation.Curve.easeOut.value(at: 0.25) > 0.35)
        #expect(Animation.Curve.easeIn.value(at: 0.25) < 0.15)
    }
}


