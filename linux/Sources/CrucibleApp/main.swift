import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

enum CrucibleLinux {
    static let version = "0.1.2"
    static let build = "3"
}

/// Crucible for Linux.
///
///     crucible [--couch] [--light] [--fullscreen]
@MainActor
func runCrucible() -> Int32 {
    let arguments = CommandLine.arguments
    if arguments.contains("--version") {
        print("crucible \(CrucibleLinux.version)")
        return 0
    }
    LinuxSetup.install()
    Theme.current.density = arguments.contains("--couch") ? .couch : .desk
    Theme.current.palette = arguments.contains("--light") ? .light : .dark
    let loop = EventLoop()
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
    var running = true
    coordinator.onQuit = { running = false }
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
    }
    scheduleCaptures(arguments, window: window, coordinator: coordinator) { running = false }
    loop.run { !running }
    signals.forEach { $0.cancel() }
    PlayerScreen.active?.close()
    UserDefaults.standard.synchronize()
    window.close()
    let deadline = Window.now() + 2
    loop.run { PlayerScreen.pendingStop == nil || Window.now() > deadline }
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


/// `--capture SECONDS:KEYS:PATH` (repeatable, for headless checks): after SECONDS, presses KEYS (`d` down, `u` up, `l` left,
/// `r` right, `e` Enter, `x` Escape, in order), waits a moment and writes the window to PATH; the app quits after the last.
@MainActor
func scheduleCaptures(_ arguments: [String], window: Window, coordinator: AppCoordinator, done: @escaping () -> Void) {
    let specs = arguments.indices.filter { arguments[$0] == "--capture" && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    guard !specs.isEmpty else { return }
    for (index, spec) in specs.enumerated() {
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let seconds = Double(parts[0]) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                let keys: [Character: Key] = ["d": .down, "u": .up, "l": .left, "r": .right, "e": .return, "x": .escape]
                for character in parts[1] { if let key = keys[character] { window.handleKey(KeyEvent(key: key)) } }
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
