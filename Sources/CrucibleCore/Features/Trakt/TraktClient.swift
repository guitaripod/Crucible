import Foundation
import MidgarCore

/// What can go wrong talking to Trakt, in the words a viewer needs to act on it.
package enum TraktError: Error, Equatable, LocalizedError, Sendable {
    case notAvailable
    case signedOut
    case invalidRequest
    /// The token was refused even after a refresh: the viewer must connect again.
    case unauthorized
    /// A development app that Trakt only lets its owner and allow-listed accounts use (418), or an app Trakt has not approved (403).
    case notAllowed
    case notFound
    /// Already done recently: a duplicate scrobble or check-in. Carries Trakt's answer for the caller to read.
    case conflict(Data)
    case invalidItem
    /// The account is at one of its limits (420).
    case accountLimit
    /// Trakt locked or deactivated the account (423).
    case locked
    /// Only Trakt VIP accounts can do this (426).
    case vipOnly(URL?)
    case rateLimited
    case unavailable
    case offline
    case unexpected(Int)
    case decoding

    package var errorDescription: String? {
        switch self {
        case .notAvailable: return String(localized: "This build of Crucible can't connect to Trakt.", comment: "Trakt error when the build has no Trakt app")
        case .signedOut, .unauthorized: return String(localized: "Trakt signed Crucible out. Connect again in Settings.", comment: "Trakt error when the token is no longer accepted")
        case .notAllowed: return String(localized: "Trakt isn't letting this account use Crucible yet.", comment: "Trakt error for a development app or an unapproved app")
        case .notFound: return String(localized: "Trakt doesn't know this title.", comment: "Trakt error for an unknown item")
        case .conflict: return String(localized: "Trakt already has this.", comment: "Trakt error for a duplicate")
        case .invalidRequest, .invalidItem, .decoding: return String(localized: "Trakt couldn't use what Crucible sent.", comment: "Trakt error for a rejected request")
        case .accountLimit: return String(localized: "Your Trakt account is at one of its limits.", comment: "Trakt error 420")
        case .locked: return String(localized: "Trakt has locked this account. Contact Trakt support to unlock it.", comment: "Trakt error 423")
        case .vipOnly: return String(localized: "This needs Trakt VIP.", comment: "Trakt error 426")
        case .rateLimited: return String(localized: "Trakt asked Crucible to slow down. It will try again shortly.", comment: "Trakt error 429")
        case .unavailable, .unexpected: return String(localized: "Trakt isn't answering right now. Crucible will try again later.", comment: "Trakt error for a server problem")
        case .offline: return String(localized: "You're offline. Crucible will send this to Trakt when you're back.", comment: "Trakt error when offline")
        }
    }

    /// Worth trying again later from the outbox, as opposed to a refusal that will not change by waiting.
    package var isTransient: Bool {
        switch self {
        case .rateLimited, .unavailable, .offline, .unexpected: return true
        default: return false
        }
    }

    static func status(_ code: Int, data: Data, upgradeURL: String?) -> TraktError? {
        switch code {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403, 418: return .notAllowed
        case 404: return .notFound
        case 409: return .conflict(data)
        case 400, 412, 422: return .invalidItem
        case 420: return .accountLimit
        case 423: return .locked
        case 426: return .vipOnly(upgradeURL.flatMap(URL.init(string:)))
        case 429: return .rateLimited
        case 500..<600: return .unavailable
        default: return .unexpected(code)
        }
    }
}

/// Where a device sign-in stands after one poll.
package enum TraktDevicePoll: Equatable, Sendable {
    case pending
    case slowDown
    case approved(TraktToken)
    case expired
    case denied
    case invalid
    case notAllowed
}

/// The one network call the client makes, injectable so tests answer without a network.
package struct TraktTransport: Sendable {
    package var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    package init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    package static let live = TraktTransport { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TraktError.unavailable }
        return (data, http)
    }
}

/// Talks to Trakt for every feature: adds the headers Trakt requires, the viewer's token where a route needs it, refreshes
/// that token before it runs out (and once more when Trakt refuses it), keeps writes one second apart as Trakt asks, and
/// waits out a rate limit before trying again.
package actor TraktClient {
    package static let shared = TraktClient()

    private let transport: TraktTransport
    private let tokens: TraktTokenStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private let clientID: @Sendable () -> String?
    private var lastWrite: ContinuousClock.Instant?

    /// The shortest gap between two writes; Trakt allows one a second per account.
    static let writeSpacing: Duration = .milliseconds(1100)

    package init(
        transport: TraktTransport = .live,
        tokens: TraktTokenStore = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        clientID: @escaping @Sendable () -> String? = { TraktConfig.clientID }
    ) {
        self.transport = transport
        self.tokens = tokens
        self.sleep = sleep
        self.clientID = clientID
    }

    package func send<T: Decodable & Sendable>(_ endpoint: TraktEndpoint, as type: T.Type = T.self) async throws -> T {
        let data = try await perform(endpoint)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            MidgarLog.error("Trakt \(endpoint.path) answered in a shape Crucible can't read: \(error)", category: .trakt)
            throw TraktError.decoding
        }
    }

    package func sendVoid(_ endpoint: TraktEndpoint) async throws {
        _ = try await perform(endpoint)
    }

    /// Sends `endpoint` and returns the body of a successful answer.
    package func perform(_ endpoint: TraktEndpoint) async throws -> Data {
        guard let clientID = clientID() else { throw TraktError.notAvailable }
        var token: String?
        if endpoint.requiresToken {
            token = try await tokens.validAccessToken { refresh in try await self.refresh(refresh, clientID: clientID) }
        }
        var refreshedAfterRefusal = false
        var attempts = 0
        while true {
            attempts += 1
            if endpoint.isWrite { try await spaceWrites() }
            let request = try endpoint.urlRequest(token: token, clientID: clientID)
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as TraktError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw (error as? URLError)?.isOffline == true ? TraktError.offline : TraktError.unavailable
            }
            guard let failure = TraktError.status(response.statusCode, data: data, upgradeURL: response.value(forHTTPHeaderField: "X-Upgrade-URL")) else { return data }
            switch failure {
            case .unauthorized where endpoint.requiresToken && !refreshedAfterRefusal:
                refreshedAfterRefusal = true
                token = try await tokens.forceRefresh { refresh in try await self.refresh(refresh, clientID: clientID) }
                continue
            case .rateLimited where attempts < 3:
                let wait = Self.retryAfter(response) ?? .seconds(2 << attempts)
                MidgarLog.notice("Trakt rate limited \(endpoint.path); waiting \(wait)", category: .trakt)
                try await sleep(min(wait, .seconds(30)))
                continue
            case .unavailable where attempts < 2 && !endpoint.isAuthFlow:
                try await sleep(.seconds(2))
                continue
            default:
                if case .conflict = failure {} else {
                    MidgarLog.notice("Trakt \(endpoint.method) \(endpoint.path) answered \(response.statusCode)", category: .trakt)
                }
                throw failure
            }
        }
    }

    /// Asks once whether the viewer approved `deviceCode`, without retrying: the link session polls at Trakt's interval.
    package func pollDeviceToken(_ deviceCode: String) async throws -> TraktDevicePoll {
        guard let clientID = clientID() else { throw TraktError.notAvailable }
        let request = try TraktEndpoint.deviceToken(deviceCode: deviceCode).urlRequest(token: nil, clientID: clientID)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .pending
        }
        switch response.statusCode {
        case 200:
            guard let token = try? JSONDecoder().decode(TraktToken.self, from: data) else { throw TraktError.decoding }
            return .approved(token)
        case 400: return .pending
        case 429: return .slowDown
        case 404, 409: return .invalid
        case 410: return .expired
        case 418: return .denied
        case 403: return .notAllowed
        default: return .pending
        }
    }

    /// Exchanges a refresh token for new tokens. Refresh tokens are single use, so the store saves the answer before anything else runs.
    private func refresh(_ refreshToken: String, clientID: String) async throws -> TraktToken {
        let request = try TraktEndpoint.refreshToken(refreshToken).urlRequest(token: nil, clientID: clientID)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            MidgarLog.error("Trakt token refresh answered \(response.statusCode)", category: .trakt)
            throw response.statusCode == 400 || response.statusCode == 401 ? TraktError.unauthorized : TraktError.unavailable
        }
        return try JSONDecoder().decode(TraktToken.self, from: data)
    }

    /// Takes the next free write slot before waiting for it, so writes that arrive together still leave a second apart.
    private func spaceWrites() async throws {
        let now = ContinuousClock.now
        let slot = lastWrite.map { max(now, $0 + Self.writeSpacing) } ?? now
        lastWrite = slot
        if slot > now { try await sleep(slot - now) }
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value), seconds >= 0 else { return nil }
        return .milliseconds(Int(seconds * 1000))
    }
}

private extension URLError {
    var isOffline: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

extension MidgarLog.Category {
    package static let trakt = MidgarLog.Category("trakt")
}
