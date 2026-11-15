#if !canImport(os)
import Foundation
import MidgarCore

/// `os.Logger` for the demo on Linux, where its lines land in Crucible's own log.
struct Logger: Sendable {
    init(subsystem: String, category: String) {}

    func notice(_ message: DemoLogMessage) {
        MidgarLog.notice(message.text, category: .lifecycle)
    }

    func error(_ message: DemoLogMessage) {
        MidgarLog.error(message.text, category: .lifecycle)
    }
}

/// How `os.Logger` treats an interpolated value; Crucible's own log keeps every value, so the choice changes nothing here.
enum DemoLogPrivacy: Sendable {
    case `public`
    case `private`
}

/// A log line with values interpolated as `os.Logger` takes them, `privacy:` included.
struct DemoLogMessage: ExpressibleByStringInterpolation, Sendable {
    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: some Any, privacy: DemoLogPrivacy = .private) {
            text += String(describing: value)
        }
    }

    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }
}

/// `os.OSAllocatedUnfairLock` for the demo on Linux: state that only the closure handed to `withLock` touches.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
