import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

enum CrucibleLinux {
    static let version = "0.4.0"
    static let build = "6"
}

/// Crucible for Linux.
///
///     crucible [--couch] [--light] [--fullscreen] [--new-instance] [crucible://...]
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
    Theme.current.density = arguments.contains("--couch") ? .couch : .desk
    Theme.current.cardZoom = CardZoom.saved
    Theme.current.palette = arguments.contains("--light") ? .light : .dark
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
    if arguments.contains("--fullscreen") || arguments.contains("--couch") { window.setFullscreen(true) }
    TextRenderer.warmUp(Theme.current.type.all, scale: window.scale)
    let coordinator = AppCoordinator(window: window)
    let memoryPressure = MemoryPressure(loop: loop, window: window)
    ServerRouteMonitor.shared.start()
    var running = true
    coordinator.onQuit = { running = false }
    MediaControls.onQuit = { coordinator.onQuit?() }
    instance?.onOpen = { urls, token in coordinator.open(urls, activationToken: token) }
    let signals = quitOnSignals(coordinator)
    if let file = ProcessInfo.processInfo.environment["CRUCIBLE_PLAY_FILE"] {
        let player = PlayerScreen(source: .file(URL(fileURLWithPath: file), title: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent))
        player.onClose = { running = false }
        window.contentView = player
        window.background = .black
        window.focus.focus(player, animated: false)
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
    scheduleCaptures(arguments, window: window, coordinator: coordinator) { running = false }
    loop.run { !running }
    signals.forEach { $0.cancel() }
    withExtendedLifetime(memoryPressure) {}
    PlayerScreen.active?.close()
    UserDefaults.standard.synchronize()
    window.close()
    let deadline = Window.now() + 2
    loop.run { PlayerScreen.pendingStop == nil || Window.now() > deadline }
    instance?.close()
    return 0
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

/// The key a `--capture` letter stands for.
func captureKey(_ character: Character) -> KeyEvent? {
    let keys: [Character: Key] = ["d": .down, "u": .up, "l": .left, "r": .right, "e": .return, "x": .escape, "m": .menu, "p": .mediaPlay,
                                  "<": .back, ">": .forward]
    if let key = keys[character] { return KeyEvent(key: key) }
    if character == ";" { return KeyEvent(key: .character(","), modifiers: .control) }
    if character.isNumber || character == "+" || character == "-" {
        return KeyEvent(key: .character(character == "+" ? "=" : character), modifiers: .control)
    }
    return KeyEvent(key: .character(character), text: String(character))
}

/// `--capture SECONDS:KEYS:PATH` (repeatable, for headless checks): after SECONDS, presses KEYS (`d` down, `u` up, `l` left,
/// `r` right, `e` Enter, `x` Escape, `m` Menu, `p` Play/Pause, `<` and `>` the back and forward keys, `;` Ctrl+comma, a digit
/// Ctrl with it, `+` and `-` Ctrl with them, any other character itself, in order),
/// waits a moment and writes the window to PATH; the app quits after the last.
@MainActor
func scheduleCaptures(_ arguments: [String], window: Window, coordinator: AppCoordinator, done: @escaping () -> Void) {
    let specs = arguments.indices.filter { arguments[$0] == "--capture" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    guard !specs.isEmpty else { return }
    for (index, spec) in specs.enumerated() {
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let seconds = Double(parts[0]) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                for character in parts[1] { if let event = captureKey(character) { window.handleKey(event) } }
            }
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

let status = MainActor.assumeIsolated { runCrucible() }
exit(status)
