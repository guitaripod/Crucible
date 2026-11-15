import CLinuxServices
import Foundation
import Kiln

/// The desktop's media controls (MPRIS on the session bus): Plasma's media widget, the lock screen and the keyboard's
/// media keys see what plays and can play, pause, stop, seek and skip it.
@MainActor
final class MediaControls {
    enum Command {
        case playPause, play, pause, stop, next, previous, raise, quit
        case seek(by: Double)
        case setPosition(Double)
    }

    var onCommand: ((Command) -> Void)?
    private let handle: OpaquePointer
    private weak var loop: EventLoop?

    init?(loop: EventLoop) {
        let context = UnsafeMutableRawPointer(bitPattern: 1)
        guard let handle = crucible_mpris_create(MediaControls.handler, context) else { return nil }
        self.handle = handle
        self.loop = loop
        loop.add(fd: crucible_mpris_fd(handle)) { [weak self] _ in
            guard let self else { return }
            crucible_mpris_process(self.handle)
        }
        MediaControls.current = self
    }

    /// Quits the app for the desktop's media controls (MPRIS Quit).
    static var onQuit: (() -> Void)?

    /// The controls the bus callbacks reach; one player plays at a time.
    private static weak var current: MediaControls?

    private static let handler: crucible_mpris_handler = { _, command, value in
        let micros = value
        MainActor.assumeIsolated {
            guard let controls = MediaControls.current else { return }
            let mapped: Command
            switch command {
            case CRUCIBLE_MPRIS_PLAY_PAUSE: mapped = .playPause
            case CRUCIBLE_MPRIS_PLAY: mapped = .play
            case CRUCIBLE_MPRIS_PAUSE: mapped = .pause
            case CRUCIBLE_MPRIS_STOP: mapped = .stop
            case CRUCIBLE_MPRIS_NEXT: mapped = .next
            case CRUCIBLE_MPRIS_PREVIOUS: mapped = .previous
            case CRUCIBLE_MPRIS_RAISE: mapped = .raise
            case CRUCIBLE_MPRIS_QUIT: mapped = .quit
            case CRUCIBLE_MPRIS_SEEK: mapped = .seek(by: Double(micros) / 1_000_000)
            case CRUCIBLE_MPRIS_SET_POSITION: mapped = .setPosition(Double(micros) / 1_000_000)
            default: return
            }
            controls.onCommand?(mapped)
        }
    }

    /// Publishes what plays and where.
    func update(playing: Bool?, title: String, show: String?, artURL: URL?, duration: Double, position: Double, canGoNext: Bool) {
        let status = playing == nil ? "Stopped" : playing! ? "Playing" : "Paused"
        crucible_mpris_update(handle, status, title, show, artURL?.absoluteString, Int64(duration * 1_000_000), Int64(position * 1_000_000), canGoNext)
    }

    func seeked(to position: Double) {
        crucible_mpris_seeked(handle, Int64(position * 1_000_000))
    }

    func close() {
        loop?.remove(fd: crucible_mpris_fd(handle))
        crucible_mpris_destroy(handle)
        if MediaControls.current === self { MediaControls.current = nil }
    }
}
