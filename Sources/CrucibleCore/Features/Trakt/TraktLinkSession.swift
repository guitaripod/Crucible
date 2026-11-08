import Foundation
import MidgarCore

/// The code the viewer approves Crucible with, where to approve it, and when it stops working.
package struct TraktLinkCode: Equatable, Sendable {
    package let userCode: String
    package let verificationURL: URL
    package let expiresAt: Date

    package init(userCode: String, verificationURL: URL, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
    }

    /// The code split in two halves of four, the way the screens show it.
    package var displayGroups: [String] {
        let characters = Array(userCode.uppercased())
        guard characters.count == 8 else { return [userCode.uppercased()] }
        return [String(characters[0..<4]), String(characters[4..<8])]
    }
}

package enum TraktLinkState: Equatable, Sendable {
    case requesting
    case waiting(TraktLinkCode)
    case approved(TraktToken)
    case expired
    case denied
    case notAllowed
    case failed(String)

    package var isTerminal: Bool {
        switch self {
        case .requesting, .waiting: return false
        default: return true
        }
    }
}

/// Connects a Trakt account with a device code, on every device: Trakt hands out an eight-character code, the viewer
/// approves it at auth.trakt.tv/activate on any phone or computer, and this polls at the interval Trakt sets until the
/// approval arrives, the code expires or the viewer says no. Cancel the task iterating `states()` to stop.
package struct TraktLinkSession: Sendable {
    package struct Transport: Sendable {
        package var requestCode: @Sendable () async throws -> TraktDeviceCode
        package var poll: @Sendable (_ deviceCode: String) async throws -> TraktDevicePoll

        package init(
            requestCode: @escaping @Sendable () async throws -> TraktDeviceCode,
            poll: @escaping @Sendable (_ deviceCode: String) async throws -> TraktDevicePoll
        ) {
            self.requestCode = requestCode
            self.poll = poll
        }

        package static let live = Transport(
            requestCode: { try await TraktClient.shared.send(.deviceCode, as: TraktDeviceCode.self) },
            poll: { code in try await TraktClient.shared.pollDeviceToken(code) }
        )
    }

    private let transport: Transport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    package init(
        transport: Transport = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    package func states() -> AsyncStream<TraktLinkState> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.requesting)
                let last = await run { continuation.yield($0) }
                continuation.yield(last)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(yield: (TraktLinkState) -> Void) async -> TraktLinkState {
        let code: TraktDeviceCode
        do {
            code = try await transport.requestCode()
        } catch let error as TraktError {
            return error == .notAllowed ? .notAllowed : .failed(error.localizedDescription)
        } catch {
            return .failed(TraktError.unavailable.localizedDescription)
        }
        let expiresAt = now().addingTimeInterval(TimeInterval(code.expiresIn))
        let url = URL(string: code.verificationURL) ?? TraktConfig.activationURL
        yield(.waiting(TraktLinkCode(userCode: code.userCode, verificationURL: url, expiresAt: expiresAt)))
        var interval = max(1, code.interval)
        while now() < expiresAt {
            do {
                try await sleep(.seconds(interval))
            } catch {
                return .failed(TraktError.unavailable.localizedDescription)
            }
            if Task.isCancelled { return .failed("") }
            let poll: TraktDevicePoll
            do {
                poll = try await transport.poll(code.deviceCode)
            } catch {
                if Task.isCancelled { return .failed("") }
                continue
            }
            switch poll {
            case .pending: continue
            case .slowDown: interval += 1
            case .approved(let token): return .approved(token)
            case .expired, .invalid: return .expired
            case .denied: return .denied
            case .notAllowed: return .notAllowed
            }
        }
        return .expired
    }
}
