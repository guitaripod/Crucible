import CrucibleCore
import CrucibleDemo
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln

enum CrucibleLinux {
    static let version = "2.16.0"
    static let build = "36"
}

/// Crucible for Linux.
///
///     crucible [--steam-deck | --desktop] [--light] [--fullscreen] [--new-instance] [crucible://...]
///     crucible --check-news   (the news timer: announce what arrived on the server, then quit)
///
/// A launch while Crucible runs hands its `crucible://` links to the running app and quits; `--new-instance` (and the
/// headless `--capture` runs) always open their own window.
@MainActor
func runCrucible() -> Int32 {
    let arguments = CommandLine.arguments
    if arguments.contains("--version") {
        print("crucible \(CrucibleLinux.version)")
        return 0
    }
    LinuxSetup.install()
    if arguments.contains("--display-guard") { return MatchContent.runGuard(arguments: arguments) }
    DemoMode.shared.install(DemoLibraryProvider())
    HostedBrain.installDemo(DemoBrain())
    OwnModel.install()
    if arguments.contains("--check-news") { return ClosedNewsCheck.run(loop: EventLoop()) }
    settleWelcome()
    LinuxDisplay.restore(arguments: arguments)
    MatchContent.restoreLeftover()
    let loop = EventLoop()
    let links = AppInstance.links(in: arguments)
    let activationToken = AppInstance.takeActivationToken()
    var instance: AppInstance?
    if !arguments.contains("--new-instance") && !arguments.contains("--capture") {
        switch AppInstance.claim(loop: loop, forwarding: links, activationToken: activationToken) {
        case .forwarded: return 0
        case .claimed(let claimed): instance = claimed
        case .unavailable: break
        }
    }
    let window: Window
    do {
        window = try Window(title: "Crucible", appID: "org.guitaripod.Crucible", loop: loop,
                            shaderCache: AppPlatform.cachesDirectory.appendingPathComponent("shaders.cache"))
    } catch {
        FileHandle.standardError.write(Data("crucible: \(error)\n".utf8))
        return 1
    }
    window.hudTraceFile = AppPlatform.cachesDirectory.appendingPathComponent("frame-trace.txt")
    if arguments.contains("--fullscreen") || arguments.contains("--couch") || arguments.contains("--steam-deck") { window.setFullscreen(true) }
    LinuxDisplay.applyCanvas(to: window)
    TextRenderer.warmUp(Theme.current.type.all, scale: window.scale)
    DesktopAccessibility.apply(to: window)
    window.makeTooltip = { TooltipView(text: $0) }
    let coordinator = AppCoordinator(window: window)
    LinuxDisplay.windows = { coordinator.allWindows }
    let memoryPressure = MemoryPressure(loop: loop) { coordinator.allWindows }
    let desktopSettings = DesktopSettingsWatch(loop: loop) { coordinator.allWindows }
    let gamepads = Gamepads { coordinator.keyWindow }
    gamepads?.onUse = { CouchOffer.consider(in: coordinator.keyWindow) }
    if ProcessInfo.processInfo.environment["CRUCIBLE_VIRTUAL_PAD"] == "1", gamepads?.attachVirtualPad() == true { CapturePad.pad = gamepads }
    ServerRouteMonitor.shared.start()
    var running = true
    coordinator.onQuit = { running = false }
    MediaControls.onQuit = { coordinator.onQuit?() }
    SoftwareUpdate.shared.onQuit = { coordinator.onQuit?() }
    instance?.onOpen = { urls, token in coordinator.open(urls, activationToken: token) }
    let signals = quitOnSignals(coordinator)
    if let file = ProcessInfo.processInfo.environment["CRUCIBLE_PLAY_FILE"] {
        let player = PlayerScreen(source: .file(URL(fileURLWithPath: file), title: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent))
        player.onClose = { running = false }
        window.contentView = player
        window.background = .black
        window.focus.focus(player, animated: false)
    } else if let link = ProcessInfo.processInfo.environment["CRUCIBLE_PLAY_LINK"].flatMap(WebLink.init) {
        let player = PlayerScreen(source: .web(WebPlayback(entry: WebEntry(id: WebLink.youTubeVideoID(in: link.url) ?? link.url, url: link.url, title: ""))))
        player.onClose = { running = false }
        window.useImages(diskDirectory: LinuxSession.imageCacheDirectory, fetch: { try await WebArtwork.fetch($0) })
        window.contentView = player
        window.background = .black
        window.focus.focus(player, animated: false)
    } else if ProcessInfo.processInfo.environment["CRUCIBLE_SCREEN"] == "sports", let fixture = ProcessInfo.processInfo.environment["CRUCIBLE_SPORTS_FIXTURE"] {
        let stack = NavigationView(root: SportsResearchScreen(source: SportsFixture(url: URL(fileURLWithPath: fixture))))
        window.contentView = stack
        window.focus.focus(stack, animated: false)
    } else if ProcessInfo.processInfo.environment["CRUCIBLE_SCREEN"] == "sports-schedule", let fixture = ProcessInfo.processInfo.environment["CRUCIBLE_SPORTS_FIXTURE"],
              let report = (try? Data(contentsOf: URL(fileURLWithPath: fixture))).flatMap({ try? JSONDecoder().decode(SportsReport.self, from: $0) }) {
        let source = SportsFixture(url: URL(fileURLWithPath: fixture))
        let stack = NavigationView(root: SportsScheduleScreen(source: source, settings: report.settings) { _ in })
        window.contentView = stack
        window.focus.focus(stack, animated: false)
    } else if ProcessInfo.processInfo.environment["CRUCIBLE_SCREEN"] == "settings" {
        let api = APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "")
        let stack = NavigationView(root: SettingsScreen(api: api))
        window.contentView = stack
        window.focus.focus(stack, animated: false)
    } else {
        coordinator.start()
        for url in links { coordinator.router.handle(url) }
        if let link = ProcessInfo.processInfo.environment["CRUCIBLE_OPEN_LINK"].flatMap(URL.init(string:)) { coordinator.router.handle(link) }
    }
    if !arguments.contains("--capture") || ProcessInfo.processInfo.environment["CRUCIBLE_RELEASES_URL"] != nil { SoftwareUpdate.shared.checkIfDue() }
    scheduleCaptures(arguments, window: window, coordinator: coordinator) { running = false }
    loop.run { !running }
    signals.forEach { $0.cancel() }
    withExtendedLifetime(memoryPressure) {}
    withExtendedLifetime(desktopSettings) {}
    withExtendedLifetime(gamepads) {}
    PlayerScreen.active?.close()
    coordinator.closeAllPlayers()
    WebService.shared.library.flush()
    UserDefaults.standard.synchronize()
    window.close()
    coordinator.allWindows.forEach { $0.close() }
    let deadline = Window.now() + 2
    loop.run(timeoutMilliseconds: 16) { PlayerScreen.pendingStop == nil || Window.now() > deadline }
    instance?.close()
    return 0
}

/// Decides once per install whether the first library opens with the welcome (`WelcomeLedger`), before a sign-in can save a
/// server. A debug build stages it for a headless check with `CRUCIBLE_WELCOME=1`; a release build is staged through the
/// settings file instead, `MOCK_DEFAULTS='{"welcome.v1.state": "owed"}'` with `mock-session.sh`.
@MainActor
func settleWelcome() {
    #if DEBUG
    if ProcessInfo.processInfo.environment["CRUCIBLE_WELCOME"] == "1" { WelcomeLedger.shared.stageFreshInstall(owesWelcome: true) }
    #endif
    WelcomeLedger.shared.settleAtLaunch()
}

/// SIGTERM (logout, `kill`), SIGINT (Ctrl+C) and SIGHUP (the terminal closing) quit the way Ctrl+Q does: the player
/// stops, the server hears where, and the window closes, instead of the process dying mid-title.
@MainActor
func quitOnSignals(_ coordinator: AppCoordinator) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { coordinator.onQuit?() } }
        source.resume()
        return source
    }
}

/// The virtual gamepad of a headless check (`CRUCIBLE_VIRTUAL_PAD=1`), which `~` capture letters press.
@MainActor
enum CapturePad {
    static var pad: Gamepads?
}

/// Presses the virtual pad's button for a `~` capture letter: a lowercase one taps it, an uppercase direction holds it a
/// second and a quarter; `t` tilts the right stick and `f` and `F` pull the right and left trigger for a second (a virtual
/// trigger rests at -1, the bottom of SDL's axis range, which a gamepad reads as not pulled).
@MainActor
func pressCapturePad(_ letter: Character) {
    guard let pad = CapturePad.pad else { return }
    let buttons: [Character: GamepadButton] = ["a": .south, "b": .east, "x": .west, "y": .north, "s": .start, "q": .leftShoulder,
                                               "w": .rightShoulder, "u": .dpadUp, "d": .dpadDown, "l": .dpadLeft, "r": .dpadRight]
    func release(after seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(body) }
    }
    switch letter {
    case "t":
        pad.moveVirtual(axis: 2, to: 1)
        release(after: 0.6) { pad.moveVirtual(axis: 2, to: 0) }
    case "f", "F":
        let axis = letter == "f" ? 5 : 4
        pad.moveVirtual(axis: axis, to: 1)
        release(after: 1) { pad.moveVirtual(axis: axis, to: -1) }
    default:
        let held = letter.isUppercase
        guard let button = buttons[Character(letter.lowercased())] else { return }
        pad.pressVirtual(button, down: true)
        release(after: held ? 1.25 : 0.1) { pad.pressVirtual(button, down: false) }
    }
}

/// The key a `--capture` letter stands for.
func captureKey(_ character: Character) -> KeyEvent? {
    let keys: [Character: Key] = ["d": .down, "u": .up, "l": .left, "r": .right, "e": .return, "x": .escape, "m": .menu, "p": .mediaPlay,
                                  "<": .back, ">": .forward]
    if let key = keys[character] { return KeyEvent(key: key) }
    if character == ";" { return KeyEvent(key: .character(","), modifiers: .control) }
    if character == "!" { return KeyEvent(key: .f10) }
    if character == "?" { return KeyEvent(key: .character("?"), text: "?", modifiers: [.control, .shift]) }
    if character.isASCII && character.isNumber || character == "+" || character == "-" {
        return KeyEvent(key: .character(character == "+" ? "=" : character), modifiers: .control)
    }
    return KeyEvent(key: .character(character), text: String(character))
}

/// Presses a capture's keys in order, moving the pointer for each `{X,Y}` among them, turning the wheel for each `{wN}`,
/// pressing and releasing the primary button for `[` and `]`, clicking the secondary for `#` and the middle for `*`,
/// holding Ctrl for the letter after a `^` and waiting the milliseconds of a `(MS)` before going on, then calls `finished`.
@MainActor
func performCaptureInput(_ keys: String, in window: Window, then finished: @escaping @MainActor () -> Void) {
    var rest = Substring(keys)
    while let character = rest.first {
        if character == "(", let close = rest.firstIndex(of: ")"), let wait = Double(rest[rest.index(after: rest.startIndex)..<close]) {
            let after = String(rest[rest.index(after: close)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) {
                MainActor.assumeIsolated { performCaptureInput(after, in: window, then: finished) }
            }
            return
        }
        if character == "{", let close = rest.firstIndex(of: "}") {
            let body = rest[rest.index(after: rest.startIndex)..<close]
            if body.first == "w", let notches = Float(body.dropFirst()) {
                window.handleScroll(ScrollEvent(dx: 0, dy: notches * 15, notchesY: notches, source: .wheel))
            } else {
                let numbers = body.split(separator: ",").compactMap { Float($0) }
                if numbers.count == 2 { window.handlePointerMoved(to: Point(x: numbers[0], y: numbers[1])) }
            }
            rest = rest[rest.index(after: close)...]
            continue
        }
        if character == "^", let letter = rest.dropFirst().first {
            window.handleKey(KeyEvent(key: .character(letter), modifiers: .control))
            rest = rest.dropFirst(2)
            continue
        }
        if character == "~", let letter = rest.dropFirst().first {
            pressCapturePad(letter)
            rest = rest.dropFirst(2)
            continue
        }
        switch character {
        case "[": window.handlePointerButton(.primary, pressed: true)
        case "]": window.handlePointerButton(.primary, pressed: false)
        case "#":
            window.handlePointerButton(.secondary, pressed: true)
            window.handlePointerButton(.secondary, pressed: false)
        case "*":
            window.handlePointerButton(.middle, pressed: true)
            window.handlePointerButton(.middle, pressed: false)
        default:
            if let event = captureKey(character) { window.handleKey(event) }
        }
        rest = rest.dropFirst()
    }
    finished()
}

/// `--capture SECONDS:KEYS:PATH` (repeatable, for headless checks): after SECONDS, presses KEYS (`d` down, `u` up, `l` left,
/// `r` right, `e` Enter, `x` Escape, `m` Menu, `p` Play/Pause, `<` and `>` the back and forward keys, `;` Ctrl+comma, a digit
/// Ctrl with it, `+` and `-` Ctrl with them, `!` F10, `?` Ctrl+?, `^` and a letter Ctrl with it, `{X,Y}` moves the pointer to
/// that point of the window, `{wN}` turns the wheel N notches (negative ones away from the viewer), `[` and `]` press and
/// release the primary button, `#` clicks the secondary and `*` the middle, `~` and a letter presses the virtual gamepad of
/// `CRUCIBLE_VIRTUAL_PAD=1` (see `pressCapturePad`), `(MS)` waits that many milliseconds, any other character itself, in
/// order), waits a moment and writes the window to PATH; the app quits after the last.
@MainActor
func scheduleCaptures(_ arguments: [String], window: Window, coordinator: AppCoordinator, done: @escaping () -> Void) {
    let specs = arguments.indices.filter { arguments[$0] == "--capture" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    guard !specs.isEmpty else { return }
    for (index, spec) in specs.enumerated() {
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let seconds = Double(parts[0]) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                performCaptureInput(parts[1], in: window) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        MainActor.assumeIsolated {
                            let capture = window.capture()
                            let ok = PNGWriter.write(linear: capture.pixels, width: capture.width, height: capture.height, to: parts[2])
                            print("capture \(ok ? "wrote" : "FAILED") \(parts[2])")
                            if index == specs.count - 1 { done() }
                        }
                    }
                }
            }
        }
    }
}

let status = MainActor.assumeIsolated { runCrucible() }
exit(status)
