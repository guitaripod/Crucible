#if !canImport(os)
import Foundation

/// Linux stand-in for `os.OSAllocatedUnfairLock` with the same surface, so Core's lock sites read the same on every
/// platform.
package final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    package init(initialState: State) {
        state = initialState
    }

    package func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    package func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}

extension OSAllocatedUnfairLock where State == Void {
    package convenience init() {
        self.init(initialState: ())
    }

    package func withLock<R>(_ body: () throws -> R) rethrows -> R {
        try withLock { (_: inout Void) in try body() }
    }
}
#endif
