import Foundation

/// What the Apple TV shows while it waits: the short code to type at plex.tv/link and the URL the
/// QR code opens, both for the same sign-in.
package struct PlexLinkCodes: Equatable, Sendable {
    package let shortCode: String
    package let authURL: URL
    package let expiresAt: Date

    package init(shortCode: String, authURL: URL, expiresAt: Date) {
        self.shortCode = shortCode
        self.authURL = authURL
        self.expiresAt = expiresAt
    }
}

package enum PlexLinkState: Equatable, Sendable {
    case requesting
    case waiting(PlexLinkCodes)
    case claimed(token: String)
    case expired
    case failed(String)

    package var isTerminal: Bool {
        switch self {
        case .requesting, .waiting: return false
        case .claimed, .expired, .failed: return true
        }
    }
}

/// Pure bookkeeping for the two PINs of a link session. The short code and the strong PIN are
/// requested together and shown together; whichever one yields a token first wins, and either one
/// expiring or failing ends the session so the screen never shows a dead code.
package struct PlexLinkReducer: Sendable {
    package enum Source: Sendable {
        case short, strong
    }

    private let clientIdentifier: String
    private var shortCode: PlexPinCode?
    private var strongCode: PlexPinCode?
    private var announced = false

    package init(clientIdentifier: String) {
        self.clientIdentifier = clientIdentifier
    }

    package mutating func apply(_ state: PlexPinState, from source: Source) -> PlexLinkState? {
        switch state {
        case .requesting:
            return nil
        case .waiting(let code):
            switch source {
            case .short: shortCode = code
            case .strong: strongCode = code
            }
            return announceIfReady()
        case .claimed(let token):
            return .claimed(token: token)
        case .expired:
            return .expired
        case .failed(let message):
            return .failed(message)
        }
    }

    private mutating func announceIfReady() -> PlexLinkState? {
        guard !announced, let shortCode, let strongCode,
              let url = PlexAuthURL.url(clientIdentifier: clientIdentifier, code: strongCode.code)
        else { return nil }
        announced = true
        return .waiting(PlexLinkCodes(shortCode: shortCode.code, authURL: url, expiresAt: min(shortCode.expiresAt, strongCode.expiresAt)))
    }
}

/// The Apple TV sign-in: a short code for plex.tv/link and a strong PIN for the QR code, polled
/// side by side. Cancel the task iterating `states()` to abandon both.
///
/// ```swift
/// for await state in PlexLinkSession().states() {
///     switch state {
///     case .waiting(let codes): show(codes.shortCode, qr: codes.authURL)
///     case .claimed(let token): PlexSignIn.complete(token: token)
///     case .expired, .failed: offerNewCode()
///     case .requesting: break
///     }
/// }
/// ```
package struct PlexLinkSession: Sendable {
    private let timing: PlexPinTiming
    private let transport: PlexPinTransport
    private let clock: PlexPinClock
    private let clientIdentifier: @Sendable () -> String

    package init(
        timing: PlexPinTiming = .standard,
        transport: PlexPinTransport = .live,
        clock: PlexPinClock = .live,
        clientIdentifier: @escaping @Sendable () -> String = { PlexHeaders.clientIdentifier }
    ) {
        self.timing = timing
        self.transport = transport
        self.clock = clock
        self.clientIdentifier = clientIdentifier
    }

    package func states() -> AsyncStream<PlexLinkState> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.requesting)
                await run(into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(into continuation: AsyncStream<PlexLinkState>.Continuation) async {
        let short = PlexPinAuth(strong: false, timing: timing, transport: transport, clock: clock)
        let strong = PlexPinAuth(strong: true, timing: timing, transport: transport, clock: clock)
        var reducer = PlexLinkReducer(clientIdentifier: clientIdentifier())
        let merged = Self.merge(short: short.states(), strong: strong.states())
        for await (source, state) in merged {
            guard let next = reducer.apply(state, from: source) else { continue }
            continuation.yield(next)
            if next.isTerminal { return }
        }
    }

    /// Interleaves both PIN streams. Ends when both have ended; dropping the merged stream
    /// cancels both producers.
    private static func merge(short: AsyncStream<PlexPinState>, strong: AsyncStream<PlexPinState>) -> AsyncStream<(PlexLinkReducer.Source, PlexPinState)> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await state in short { continuation.yield((.short, state)) }
                    }
                    group.addTask {
                        for await state in strong { continuation.yield((.strong, state)) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
