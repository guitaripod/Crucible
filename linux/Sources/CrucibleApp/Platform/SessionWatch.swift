import CLinuxServices
import Foundation
import Kiln

/// What logind says about this desktop while something plays (`crucible_session`): the machine about to sleep and waking,
/// and the session locking and unlocking. The desktop's version of the Apple TV app leaving the foreground. While it is
/// open it holds a delay lock on sleep, so the player can pause and tell the server where it stopped first.
@MainActor
final class SessionWatch {
    enum Event {
        case sleep, wake, lock, unlock
    }

    var onEvent: ((Event) -> Void)?
    private let handle: OpaquePointer
    private weak var loop: EventLoop?

    /// The watch the bus callbacks reach; one player plays at a time.
    private static weak var current: SessionWatch?

    init?(loop: EventLoop) {
        guard let handle = crucible_session_create(SessionWatch.handler, nil) else { return nil }
        self.handle = handle
        self.loop = loop
        loop.add(fd: crucible_session_fd(handle)) { [weak self] _ in
            guard let self else { return }
            crucible_session_process(self.handle)
        }
        crucible_session_hold_sleep(handle, true)
        SessionWatch.current = self
    }

    private static let handler: crucible_session_handler = { _, event in
        MainActor.assumeIsolated {
            guard let watch = SessionWatch.current else { return }
            switch event {
            case CRUCIBLE_SESSION_SLEEP: watch.onEvent?(.sleep)
            case CRUCIBLE_SESSION_WAKE: watch.onEvent?(.wake)
            case CRUCIBLE_SESSION_LOCK: watch.onEvent?(.lock)
            case CRUCIBLE_SESSION_UNLOCK: watch.onEvent?(.unlock)
            default: break
            }
        }
    }

    /// The player has done what it does before sleep: the machine may sleep now.
    func readyToSleep() {
        crucible_session_slept(handle)
    }

    func close() {
        loop?.remove(fd: crucible_session_fd(handle))
        crucible_session_destroy(handle)
        if SessionWatch.current === self { SessionWatch.current = nil }
    }
}
