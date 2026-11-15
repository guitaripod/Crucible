import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// Crucible for Linux.
///
///     crucible [--couch] [--light] [--fullscreen]
@MainActor
func runCrucible() -> Int32 {
    let arguments = CommandLine.arguments
    LinuxSetup.install()
    Theme.current.density = arguments.contains("--couch") ? .couch : .desk
    Theme.current.palette = arguments.contains("--light") ? .light : .dark
    let loop = EventLoop()
    let window: Window
    do {
        window = try Window(title: "Crucible", appID: "org.guitaripod.Crucible", loop: loop)
    } catch {
        FileHandle.standardError.write(Data("crucible: \(error)\n".utf8))
        return 1
    }
    if arguments.contains("--fullscreen") || arguments.contains("--couch") { window.setFullscreen(true) }
    let coordinator = AppCoordinator(window: window)
    var running = true
    coordinator.onQuit = { running = false }
    coordinator.start()
    scheduleCaptures(arguments, window: window, coordinator: coordinator) { running = false }
    loop.run { !running }
    window.close()
    return 0
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
