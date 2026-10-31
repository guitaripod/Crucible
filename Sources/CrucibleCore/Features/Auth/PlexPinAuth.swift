import Foundation
import MidgarCore

/// A requested PIN and the moment plex.tv stops honouring it.
package struct PlexPinCode: Equatable, Sendable {
    package let id: Int
    package let code: String
    package let expiresAt: Date

    package init(id: Int, code: String, expiresAt: Date) {
        self.id = id
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// Where a PIN sign-in stands. Every run starts with `requesting` and ends after exactly one of
/// `claimed`, `expired` or `failed`; cancelling the consumer ends it silently.
package enum PlexPinState: Equatable, Sendable {
    case requesting
    case waiting(PlexPinCode)
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

/// The two plex.tv calls a PIN sign-in makes.
package struct PlexPinTransport: Sendable {
    package var create: @Sendable (_ strong: Bool) async throws -> PlexPin
    package var check: @Sendable (_ pinID: Int) async throws -> PlexPin

    package init(
        create: @escaping @Sendable (_ strong: Bool) async throws -> PlexPin,
        check: @escaping @Sendable (_ pinID: Int) async throws -> PlexPin
    ) {
        self.create = create
        self.check = check
    }

    package static let live = PlexPinTransport(
        create: { strong in try await APIClient.plexTVRequest(.requestPin(strong: strong)) },
        check: { pinID in try await APIClient.plexTVRequest(.checkPin(pinId: pinID)) }
    )
}

/// Time and sleeping, injectable so polling is testable without waiting.
package struct PlexPinClock: Sendable {
    package var now: @Sendable () -> Date
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    package static let live = PlexPinClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

/// How often to poll and when to give up.
package struct PlexPinTiming: Equatable, Sendable {
    package var pollInterval: Duration
    package var fallbackLifetime: Duration
    package var lifetimeCap: Duration?
    package var maxConsecutivePollFailures: Int

    package init(pollInterval: Duration, fallbackLifetime: Duration, lifetimeCap: Duration?, maxConsecutivePollFailures: Int) {
        self.pollInterval = pollInterval
        self.fallbackLifetime = fallbackLifetime
        self.lifetimeCap = lifetimeCap
        self.maxConsecutivePollFailures = maxConsecutivePollFailures
    }

    /// Once a second until the lifetime plex.tv reports (about 15 minutes when it reports none);
    /// twenty failed polls in a row end the sign-in so the screen can offer a retry.
    package static let standard = PlexPinTiming(
        pollInterval: .seconds(1),
        fallbackLifetime: .seconds(900),
        lifetimeCap: nil,
        maxConsecutivePollFailures: 20
    )

    /// The iPhone's web sign-in: every two seconds for five minutes, riding out any number of
    /// failed polls.
    package static let phoneWeb = PlexPinTiming(
        pollInterval: .seconds(2),
        fallbackLifetime: .seconds(300),
        lifetimeCap: .seconds(300),
        maxConsecutivePollFailures: .max
    )
}

/// One PIN sign-in against plex.tv: requests a PIN, then polls until a token arrives, the PIN
/// expires or the network gives out.
///
/// ```swift
/// for await state in PlexPinAuth(strong: false).states() {
///     switch state {
///     case .waiting(let pin): show(pin.code)
///     case .claimed(let token): PlexSignIn.complete(token: token)
///     case .expired, .failed: offerRetry()
///     case .requesting: break
///     }
/// }
/// ```
/// Cancel the task iterating `states()` to stop polling.
package struct PlexPinAuth: Sendable {
    private let strong: Bool
    private let timing: PlexPinTiming
    private let transport: PlexPinTransport
    private let clock: PlexPinClock

    package init(strong: Bool, timing: PlexPinTiming = .standard, transport: PlexPinTransport = .live, clock: PlexPinClock = .live) {
        self.strong = strong
        self.timing = timing
        self.transport = transport
        self.clock = clock
    }

    package func states() -> AsyncStream<PlexPinState> {
        AsyncStream { continuation in
            let task = Task {
                await run(into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(into continuation: AsyncStream<PlexPinState>.Continuation) async {
        continuation.yield(.requesting)
        let pin: PlexPin
        do {
            pin = try await transport.create(strong)
        } catch {
            if !Task.isCancelled { continuation.yield(.failed(error.localizedDescription)) }
            return
        }
        guard !Task.isCancelled else { return }

        let code = PlexPinCode(id: pin.id, code: pin.code, expiresAt: expiry(of: pin))
        continuation.yield(.waiting(code))
        await poll(code, into: continuation)
    }

    /// The reported lifetime when there is one, never longer than the timing's cap.
    private func expiry(of pin: PlexPin) -> Date {
        var lifetime = pin.expiresIn.flatMap { $0 > 0 ? Duration.seconds($0) : nil } ?? timing.fallbackLifetime
        if let cap = timing.lifetimeCap { lifetime = min(lifetime, cap) }
        return clock.now().addingTimeInterval(lifetime.timeInterval)
    }

    private func poll(_ code: PlexPinCode, into continuation: AsyncStream<PlexPinState>.Continuation) async {
        var consecutiveFailures = 0
        var consecutiveUnknown = 0
        while true {
            do {
                try await clock.sleep(timing.pollInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let checked = try await transport.check(code.id)
                consecutiveFailures = 0
                consecutiveUnknown = 0
                if let token = checked.authToken, !token.isEmpty {
                    continuation.yield(.claimed(token: token))
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isUnknownPin(error) {
                    consecutiveUnknown += 1
                    if consecutiveUnknown >= Self.unknownPollsBeforeExpiry {
                        continuation.yield(.expired)
                        return
                    }
                } else {
                    consecutiveUnknown = 0
                }
                consecutiveFailures += 1
                MidgarLog.error("PIN poll failed (\(consecutiveFailures)): \(error.localizedDescription)", category: .networking)
                if consecutiveFailures >= timing.maxConsecutivePollFailures {
                    continuation.yield(.failed(error.localizedDescription))
                    return
                }
            }
            if clock.now() >= code.expiresAt {
                continuation.yield(.expired)
                return
            }
        }
    }

    /// A single 404 can be a transient plex.tv hiccup: the PIN counts as gone after this many in a row.
    private static let unknownPollsBeforeExpiry = 3

    /// plex.tv answers 404 once a PIN has expired or never existed.
    private static func isUnknownPin(_ error: Error) -> Bool {
        if case APIError.httpError(statusCode: 404, _) = error { return true }
        return false
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
