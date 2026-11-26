import CrucibleUI
import Foundation
import Kiln

/// The design gallery: every component with fixture content, in a window or captured offscreen to PNG files, each capture
/// optionally checked against golden thumbnails (`--check DIR`) or written as the new ones (`--update-golden DIR`).
///
///     crucible-gallery [--capture DIR [--check DIR | --update-golden DIR]] [--size 1920x1080] [--scale 2] [--density desk|couch]
///                      [--light] [--page home]
@MainActor
struct Gallery {
    let arguments = CommandLine.arguments

    func value(_ name: String) -> String? {
        arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    var size: Size {
        let parts = (value("--size") ?? "1600x900").split(separator: "x").compactMap { Float($0) }
        return parts.count == 2 ? Size(width: parts[0], height: parts[1]) : Size(width: 1600, height: 900)
    }

    var scale: Float { value("--scale").flatMap(Float.init) ?? 2 }

    func configureTheme() {
        Theme.current.density = value("--density") == "couch" ? .couch : .desk
        Theme.current.palette = arguments.contains("--light") ? .light : .dark
    }

    func makePage(_ name: String) -> View {
        switch name {
        case "cards": GalleryCards()
        case "controls": GalleryControls()
        case "grid": GalleryGrid()
        case "states": GalleryStates()
        case "tiles": GalleryTiles()
        case "panels": GalleryPanels()
        case "stats": GalleryStats()
        case "inbox": GalleryInbox()
        case "inbox-more": GalleryInbox(short: true)
        case "badges": GalleryBadges()
        default: GalleryHome()
        }
    }

    static let pages = ["home", "cards", "controls", "grid", "states", "tiles", "panels", "stats", "inbox", "badges"]

    /// Renders each page in its rest state and in the states that matter (keyboard focus, hover, what it presents), writing
    /// PNGs; returns whether every golden check passed.
    func capture(into directory: String) throws -> Bool {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let window = try Window(offscreen: size, scale: scale)
        window.useImages(diskDirectory: nil) { url in try Data(contentsOf: url) }
        GalleryArt.preload(GalleryFixtures.allArt, into: window.images!, gpu: window.gpu, scale: 1)
        let pages = value("--page").map { [$0] } ?? Self.pages
        var report: [String] = []
        for name in pages {
            let page = makePage(name)
            window.contentView = page
            window.background = Theme.current.palette.canvas
            window.render()
            settle(window)
            write(window, to: "\(directory)/\(name).png", report: &report)
            switch name {
            case "home":
                let home = page as! GalleryHome
                window.focus.focus(home.continueShelf, animated: false)
                window.handleKey(KeyEvent(key: .right))
                window.handleKey(KeyEvent(key: .right))
                settle(window)
                write(window, to: "\(directory)/home-focus-second.png", report: &report)
                window.focus.focus(home.postersShelf.seeAllButton, animated: true)
                settle(window)
                write(window, to: "\(directory)/home-focus-see-all.png", report: &report)
                window.handleKey(KeyEvent(key: .down))
                window.handleKey(KeyEvent(key: .right))
                settle(window)
                write(window, to: "\(directory)/home-focus-posters.png", report: &report)
                window.handleKey(KeyEvent(key: .down))
                settle(window)
                write(window, to: "\(directory)/home-focus-people.png", report: &report)
            case "inbox":
                let inbox = page as! GalleryInbox
                window.focus.setVisible(true)
                window.focus.focus(inbox.grid, animated: false)
                settle(window)
                write(window, to: "\(directory)/inbox-focus.png", report: &report)
            case "cards":
                let cards = page as! GalleryCards
                if let card = cards.posters.card(for: "the-last-lighthouse") {
                    let frame = card.frameInWindow
                    window.handlePointerMoved(to: Point(x: frame.midX + frame.width * 0.3, y: frame.minY + frame.width * 0.4))
                }
                settle(window)
                write(window, to: "\(directory)/cards-hover.png", report: &report)
                window.handlePointerLeft()
                window.focus.setVisible(true)
                window.focus.focus(cards.episodes.card(for: "ep2"), animated: false)
                settle(window)
                write(window, to: "\(directory)/cards-focus.png", report: &report)
            case "controls":
                let controls = page as! GalleryControls
                window.focus.setVisible(true)
                window.focus.focus(controls.rows[0][1], animated: false)
                let hovered = controls.rows[1][3].frameInWindow
                window.handlePointerMoved(to: Point(x: hovered.midX, y: hovered.midY))
                settle(window)
                write(window, to: "\(directory)/controls-focus.png", report: &report)
                window.handlePointerLeft()
                let menu = MenuView(title: "Audio", items: [
                    .init(id: "1", title: "English (TrueHD Atmos 7.1)", detail: "Original", isChecked: true),
                    .init(id: "2", title: "English (AC3 5.1)"),
                    .init(id: "3", title: "Suomi (AC3 5.1)"),
                    .init(id: "4", title: "Commentary (AAC Stereo)"),
                ], anchor: controls.rows[1][3].frameInWindow)
                menu.present(in: window)
                window.handleKey(KeyEvent(key: .down))
                settle(window)
                write(window, to: "\(directory)/controls-menu.png", report: &report)
            case "states":
                let states = page as! GalleryStates
                window.focus.setVisible(true)
                window.focus.focus(states.rows, animated: false)
                window.handleKey(KeyEvent(key: .down))
                let hovered = states.failed.subviews[2].frameInWindow
                window.handlePointerMoved(to: Point(x: hovered.midX, y: hovered.midY))
                settle(window)
                write(window, to: "\(directory)/states-focus.png", report: &report)
            case "tiles":
                let tiles = page as! GalleryTiles
                window.focus.setVisible(true)
                window.focus.focus(tiles.genres, animated: false)
                window.handleKey(KeyEvent(key: .right))
                if let card = tiles.cast.card(for: "cast.2") {
                    let frame = card.frameInWindow
                    window.handlePointerMoved(to: Point(x: frame.midX, y: frame.midY))
                }
                settle(window)
                write(window, to: "\(directory)/tiles-focus.png", report: &report)
                window.handlePointerLeft()
                window.focus.focus(tiles.letters, animated: false)
                window.handleKey(KeyEvent(key: .right))
                window.handleKey(KeyEvent(key: .down))
                settle(window)
                write(window, to: "\(directory)/tiles-letters.png", report: &report)
            case "panels":
                let panels = page as! GalleryPanels
                window.focus.setVisible(true)
                window.focus.focus(panels.field, animated: false)
                settle(window)
                write(window, to: "\(directory)/panels-focus.png", report: &report)
                let alert = panels.renameAlert()
                alert.present(in: window)
                settle(window)
                write(window, to: "\(directory)/panels-alert.png", report: &report)
                alert.dismiss()
                let rating = panels.ratingPanel()
                rating.present(in: window)
                settle(window)
                write(window, to: "\(directory)/panels-rating.png", report: &report)
                rating.dismiss()
                let shortcuts = panels.shortcuts()
                shortcuts.present(in: window)
                settle(window)
                write(window, to: "\(directory)/panels-shortcuts.png", report: &report)
                shortcuts.dismiss()
            case "stats":
                let stats = page as! GalleryStats
                window.focus.setVisible(true)
                if let last = stats.panels.last { window.focus.focus(last, animated: false, reveal: true) }
                settle(window)
                write(window, to: "\(directory)/stats-lower.png", report: &report)
                window.focus.focus(stats.moments, animated: false, reveal: true)
                settle(window)
                write(window, to: "\(directory)/stats-moments.png", report: &report)
            default:
                break
            }
        }
        report.forEach { print($0) }
        return !report.contains { $0.hasPrefix("golden ") && !$0.hasPrefix("golden ok") && !$0.hasPrefix("golden wrote") }
    }

    /// Lets a page's artwork and async work arrive for a second and a half and plays its animations for exactly as long,
    /// so what keeps moving (a spinner, a pulsing skeleton) is captured at the same moment however fast frames draw.
    private func settle(_ window: Window) {
        for _ in 0..<15 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.advance(by: 0.1)
        }
        window.settle()
    }

    private func describe(_ view: View?) -> String {
        guard let view else { return "nothing" }
        if let card = view as? CardView { return "card \(card.item.id)" }
        if let button = view as? ButtonView { return "button \(button.title ?? "?")" }
        return "\(type(of: view))"
    }

    private func write(_ window: Window, to path: String, report: inout [String]) {
        report.append("focus \(describe(window.focusedView)) visible \(window.isFocusVisible)")
        let capture = window.capture()
        let ok = PNGWriter.write(linear: capture.pixels, width: capture.width, height: capture.height, to: path)
        report.append("\(ok ? "wrote" : "FAILED") \(path) \(capture.width)x\(capture.height)")
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if let golden = value("--update-golden") {
            report.append(GalleryGolden.update(capture, name: name, golden: golden).line)
        } else if let golden = value("--check") {
            report.append(GalleryGolden.check(capture, name: name, golden: golden, captureDirectory: directory).line)
        }
    }

    /// Times Home at the window size while focus walks the shelves: CPU per frame (layout, animation, pass encoding) and
    /// the GPU time the passes took.
    func bench() throws {
        let window = try Window(offscreen: size, scale: scale)
        window.useImages(diskDirectory: nil) { url in try Data(contentsOf: url) }
        GalleryArt.preload(GalleryFixtures.allArt, into: window.images!, gpu: window.gpu, scale: scale / 2)
        let home = GalleryHome()
        window.contentView = home
        window.render()
        settle(window)
        window.focus.setVisible(true)
        window.focus.focus(home.continueShelf, animated: false)
        var cpu: [Double] = []
        var gpu: [Double] = []
        let keys: [Key] = [.right, .right, .right, .down, .down, .right, .right, .down, .up, .up, .left, .up]
        for frame in 0..<600 {
            if frame % 25 == 0 { window.handleKey(KeyEvent(key: keys[(frame / 25) % keys.count])) }
            let start = ContinuousClock.now
            window.advance(by: 1.0 / 120)
            let elapsed = ContinuousClock.now - start
            cpu.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            let milliseconds = window.gpu.takeGPUMilliseconds()
            if milliseconds > 0 { gpu.append(milliseconds) }
        }
        func describe(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "none" }
            return String(format: "median %.2f ms, p95 %.2f ms, max %.2f ms", sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!)
        }
        print("frames \(cpu.count) at \(Int(size.width * scale))x\(Int(size.height * scale))")
        print("cpu \(describe(cpu))")
        print("gpu \(describe(gpu))")
    }

    func runWindow() throws {
        let loop = EventLoop()
        let window = try Window(title: "Crucible Gallery", appID: "org.guitaripod.Crucible.Gallery", loop: loop)
        window.useImages(diskDirectory: nil) { url in try Data(contentsOf: url) }
        GalleryArt.preload(GalleryFixtures.allArt, into: window.images!, gpu: window.gpu, scale: window.scale)
        let host = GalleryHost(window: window, gallery: self)
        window.delegate = host
        if let file = value("--video") {
            let player = try VideoPlayer(gpu: window.gpu, loop: loop)
            let view = VideoView(player: player)
            window.contentView = view
            window.background = .black
            player.load(URL(fileURLWithPath: file), start: Double(value("--start") ?? "0") ?? 0)
            player.setPaused(false)
            player.onStateChange = { state in
                if ProcessInfo.processInfo.environment["GALLERY_VIDEO_LOG"] != nil {
                    print(String(format: "video t=%.2f/%.2f %dx%d hwdec=%@ paused=%d", state.position, state.duration, state.videoWidth,
                                 state.videoHeight, state.hardwareDecoder, state.isPaused ? 1 : 0))
                }
            }
            host.player = player
        } else {
            host.show(value("--page") ?? "home")
        }
        if let spec = value("--capture-after") {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let seconds = Double(parts[0]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    MainActor.assumeIsolated {
                        let capture = window.capture()
                        let peak = stride(from: 0, to: capture.pixels.count, by: 4).map { max(capture.pixels[$0], capture.pixels[$0 + 1], capture.pixels[$0 + 2]) }.max() ?? 0
                        print("capture peak=\(peak)")
                        _ = PNGWriter.write(linear: capture.pixels, width: capture.width, height: capture.height, to: parts[1])
                        host.onClose?()
                    }
                }
            }
        }
        var running = true
        host.onClose = { running = false }
        loop.run { !running }
        host.player?.shutDown()
        window.close()
    }
}

/// Switches pages with the number keys and closes on Escape when nothing else takes it.
@MainActor
final class GalleryHost: WindowDelegate {
    let window: Window
    let gallery: Gallery
    var player: VideoPlayer?
    var onClose: (() -> Void)?

    init(window: Window, gallery: Gallery) {
        self.window = window
        self.gallery = gallery
    }

    func show(_ name: String) {
        let page = gallery.makePage(name)
        window.contentView = page
        window.background = Theme.current.palette.canvas
        window.focus.focus(page, animated: false)
    }

    func window(_ window: Window, unhandledKey event: KeyEvent) -> Bool {
        switch event.text {
        case "1": show("home")
        case "2": show("cards")
        case "3": show("controls")
        case "4": show("grid")
        case "5": show("states")
        case "6": show("tiles")
        case "7": show("panels")
        case "8": show("stats")
        default:
            if event.key == .escape || (event.key == Key.character("q") && event.modifiers.contains(.control)) {
                onClose?()
                return true
            }
            if event.key == .f11 { window.setFullscreen(!window.isFullscreen) }
            return false
        }
        return true
    }

    func windowShouldClose(_ window: Window) { onClose?() }
}

MainActor.assumeIsolated {
    let gallery = Gallery()
    gallery.configureTheme()
    do {
        if gallery.arguments.contains("--bench") {
            try gallery.bench()
        } else if let directory = gallery.value("--capture") {
            if try !gallery.capture(into: directory) { exit(1) }
        } else {
            try gallery.runWindow()
        }
    } catch {
        FileHandle.standardError.write(Data("crucible-gallery: \(error)\n".utf8))
        exit(1)
    }
}
