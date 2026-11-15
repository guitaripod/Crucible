import CrucibleUI
import Foundation
import Kiln

/// The design gallery: every component with fixture content, in a window or captured offscreen to PNG files.
///
///     crucible-gallery [--capture DIR] [--size 1920x1080] [--scale 2] [--density desk|couch] [--light] [--page home]
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
        default: GalleryHome()
        }
    }

    /// Renders each page in its rest state and in the states that matter (keyboard focus, hover), writing PNGs.
    func capture(into directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let window = try Window(offscreen: size, scale: scale)
        window.useImages(diskDirectory: nil) { url in try Data(contentsOf: url) }
        GalleryArt.preload(GalleryFixtures.allArt, into: window.images!, gpu: window.gpu, scale: 1)
        let pages = value("--page").map { [$0] } ?? ["home", "cards", "controls", "grid"]
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
                window.handleKey(KeyEvent(key: .down))
                settle(window)
                write(window, to: "\(directory)/home-focus-see-all.png", report: &report)
                window.handleKey(KeyEvent(key: .down))
                window.handleKey(KeyEvent(key: .right))
                settle(window)
                write(window, to: "\(directory)/home-focus-posters.png", report: &report)
                window.handleKey(KeyEvent(key: .down))
                settle(window)
                write(window, to: "\(directory)/home-focus-people.png", report: &report)
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
            default:
                break
            }
        }
        report.forEach { print($0) }
    }

    private func settle(_ window: Window) {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
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
    }

    func runWindow() throws {
        let loop = EventLoop()
        let window = try Window(title: "Crucible Gallery", appID: "org.guitaripod.Crucible.Gallery", loop: loop)
        window.useImages(diskDirectory: nil) { url in try Data(contentsOf: url) }
        GalleryArt.preload(GalleryFixtures.allArt, into: window.images!, gpu: window.gpu, scale: window.scale)
        let host = GalleryHost(window: window, gallery: self)
        window.delegate = host
        host.show(value("--page") ?? "home")
        var running = true
        host.onClose = { running = false }
        loop.run { !running }
        window.close()
    }
}

/// Switches pages with the number keys and closes on Escape when nothing else takes it.
@MainActor
final class GalleryHost: WindowDelegate {
    let window: Window
    let gallery: Gallery
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
        if let directory = gallery.value("--capture") {
            try gallery.capture(into: directory)
        } else {
            try gallery.runWindow()
        }
    } catch {
        FileHandle.standardError.write(Data("crucible-gallery: \(error)\n".utf8))
        exit(1)
    }
}
