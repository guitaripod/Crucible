import Foundation
import MidgarCore

/// What can go wrong talking to Seerr, in the words a viewer needs to act on it.
package enum SeerrError: Error, Equatable, LocalizedError, Sendable {
    case notConnected
    case unreachable
    case notSeerr
    /// Seerr is set up for Jellyfin or Emby and cannot take a Plex sign-in.
    case notPlex
    case plexSignInOff
    /// Seerr refused the Plex account: it has no access to the server Seerr serves, or Seerr takes no new users.
    case accessDenied
    case invalidAPIKey
    case signedOut
    case notAllowed
    case quotaReached
    case alreadyRequested
    case blocklisted
    case nothingToRequest
    case notFound
    case unavailable
    case unexpected(Int)
    case decoding

    package var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Connect Seerr in Settings › Integrations first.", comment: "Seerr error when nothing is connected")
        case .unreachable: return String(localized: "Seerr isn't answering at that address.", comment: "Seerr error when the address does not answer")
        case .notSeerr: return String(localized: "Something answered at that address, but it isn't Seerr, Overseerr or Jellyseerr.", comment: "Seerr error when another service answers")
        case .notPlex: return String(localized: "This Seerr is set up for Jellyfin or Emby, not Plex.", comment: "Seerr error for a Jellyfin or Emby setup")
        case .plexSignInOff: return String(localized: "Plex sign-in is turned off in this Seerr. Turn it on in Seerr, or connect with its API key.", comment: "Seerr error when Plex sign-in is disabled")
        case .accessDenied: return String(localized: "Seerr didn't let this Plex account in. Ask whoever runs it to import or allow your account.", comment: "Seerr error when the Plex account is refused")
        case .invalidAPIKey: return String(localized: "Seerr didn't accept that API key.", comment: "Seerr error for a wrong API key")
        case .signedOut: return String(localized: "Seerr signed Crucible out. Connect again in Settings.", comment: "Seerr error when the session ended")
        case .notAllowed: return String(localized: "Your Seerr account isn't allowed to do that.", comment: "Seerr error for a missing permission")
        case .quotaReached: return String(localized: "You've used all your Seerr requests for now.", comment: "Seerr error when the request quota is used up")
        case .alreadyRequested: return String(localized: "Someone already asked for this.", comment: "Seerr error for a duplicate request")
        case .blocklisted: return String(localized: "This title is on Seerr's blocklist.", comment: "Seerr error for a blocklisted title")
        case .nothingToRequest: return String(localized: "Every season is already on its way or on the server.", comment: "Seerr error when no season is left to request")
        case .notFound: return String(localized: "Seerr doesn't know this title.", comment: "Seerr error for an unknown title")
        case .unavailable, .unexpected: return String(localized: "Seerr isn't answering right now. Try again in a moment.", comment: "Seerr error for a server problem")
        case .decoding: return String(localized: "Seerr answered in a way Crucible doesn't understand. Updating Seerr may help.", comment: "Seerr error for an unreadable answer")
        }
    }

    /// The meaning of a refusal, read from its status and Seerr's message.
    static func status(_ code: Int, data: Data, endpoint: SeerrEndpoint) -> SeerrError? {
        let message = (try? JSONDecoder().decode(SeerrMessage.self, from: data))?.text.lowercased() ?? ""
        switch code {
        case 200..<300:
            if code == 202, case .createRequest = endpoint { return .nothingToRequest }
            return nil
        case 401: return .signedOut
        case 403:
            if case .signInWithPlex = endpoint { return .accessDenied }
            if message.contains("quota") { return .quotaReached }
            if message.contains("blocklist") || message.contains("blacklist") { return .blocklisted }
            return .notAllowed
        case 404: return .notFound
        case 409: return .alreadyRequested
        case 500 where message.contains("plex login is disabled"): return .plexSignInOff
        case 500..<600: return .unavailable
        default: return .unexpected(code)
        }
    }
}

private struct SeerrMessage: Decodable {
    let message: String?
    let error: String?
    var text: String { message ?? error ?? "" }
}

/// The one network call the client makes, injectable so tests answer without a network. Seerr's cookies are kept by the
/// client itself, per viewer, so the shared cookie store never mixes two people's sessions.
package struct SeerrTransport: Sendable {
    package var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    package init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    package static let live = SeerrTransport { request in
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SeerrError.unavailable }
            return (data, http)
        } catch let error as SeerrError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SeerrError.unreachable
        }
    }
}

/// Where Seerr secrets are kept: the session cookie and the API key, one Keychain item each per viewer and server.
package struct SeerrVault: Sendable {
    package var load: @Sendable (_ key: String) -> String?
    package var save: @Sendable (_ key: String, _ value: String) -> Void
    package var delete: @Sendable (_ key: String) -> Void

    package init(load: @escaping @Sendable (String) -> String?, save: @escaping @Sendable (String, String) -> Void, delete: @escaping @Sendable (String) -> Void) {
        self.load = load
        self.save = save
        self.delete = delete
    }

    package static let live = SeerrVault(
        load: { KeychainHelper.load(key: $0) },
        save: { KeychainHelper.save(key: $0, value: $1) },
        delete: { KeychainHelper.delete(key: $0) }
    )

    package static func memory() -> SeerrVault {
        let box = Box()
        return SeerrVault(load: { box.get($0) }, save: { box.set($0, $1) }, delete: { box.set($0, nil) })
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func get(_ key: String) -> String? { lock.withLock { values[key] } }
        func set(_ key: String, _ value: String?) { lock.withLock { values[key] = value } }
    }
}

/// The Seerr a viewer connected and how Crucible signs in to it.
package struct SeerrTarget: Sendable, Equatable {
    package enum Auth: String, Codable, Sendable {
        /// Signs in with the viewer's own Plex token, so requests carry their name.
        case plex
        /// Uses the API key the viewer pasted, which acts as Seerr's administrator.
        case apiKey
    }

    package let address: URL
    package let auth: Auth
    /// The prefix of this viewer's Keychain items for this server.
    package let secretKey: String

    package init(address: URL, auth: Auth, secretKey: String) {
        self.address = address
        self.auth = auth
        self.secretKey = secretKey
    }

    var sessionKey: String { secretKey + ".session" }
    var apiKeyKey: String { secretKey + ".apikey" }
}

/// Talks to the viewer's Seerr: keeps its cookies per viewer, answers a cross-site token check when Seerr asks for one,
/// and signs in again with the Plex token once when the session has run out.
package actor SeerrClient {
    package static let shared = SeerrClient()

    private let transport: SeerrTransport
    private let vault: SeerrVault
    private let plexToken: @Sendable () -> String?
    private var target: SeerrTarget?
    private var jar: [String: String] = [:]
    private var signingIn: Task<SeerrUser, Error>?

    static let sessionCookie = "connect.sid"
    static let csrfCookie = "XSRF-TOKEN"
    static let probeTimeout: TimeInterval = 4

    package init(
        transport: SeerrTransport = .live,
        vault: SeerrVault = .live,
        plexToken: @escaping @Sendable () -> String? = { ServerBootstrap.plexTVToken }
    ) {
        self.transport = transport
        self.vault = vault
        self.plexToken = plexToken
    }

    /// Points the client at `target`, or at nothing; the saved session of that viewer comes back with it.
    package func use(_ target: SeerrTarget?) {
        guard target != self.target else { return }
        self.target = target
        signingIn = nil
        jar = [:]
        if let target, let session = vault.load(target.sessionKey) { jar[Self.sessionCookie] = session }
    }

    package var current: SeerrTarget? { target }

    package func saveAPIKey(_ key: String, for target: SeerrTarget) {
        vault.save(target.apiKeyKey, key)
    }

    /// Forgets the session and the API key of `target`.
    package func forget(_ target: SeerrTarget) {
        vault.delete(target.sessionKey)
        vault.delete(target.apiKeyKey)
        if target == self.target { jar = [:] }
    }

    /// Whether `address` is a Seerr Crucible can use, before anyone signs in.
    package func probe(_ address: URL) async throws -> SeerrPublicSettings {
        guard let statusURL = SeerrEndpoint.status.url(base: address) else { throw SeerrError.unreachable }
        var request = URLRequest(url: statusURL, timeoutInterval: Self.probeTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode), (try? JSONDecoder().decode(SeerrServerStatus.self, from: data)) != nil else { throw SeerrError.notSeerr }
        guard let settingsURL = SeerrEndpoint.publicSettings.url(base: address) else { throw SeerrError.notSeerr }
        let (settingsData, settingsResponse) = try await transport.send(URLRequest(url: settingsURL, timeoutInterval: Self.probeTimeout))
        guard (200..<300).contains(settingsResponse.statusCode) else { return SeerrPublicSettings() }
        let settings = (try? JSONDecoder().decode(SeerrPublicSettings.self, from: settingsData)) ?? SeerrPublicSettings()
        guard settings.servesPlex else { throw SeerrError.notPlex }
        return settings
    }

    /// Signs the viewer in: with their Plex token, or by checking the API key. Returns who Seerr says they are.
    @discardableResult
    package func signIn() async throws -> SeerrUser {
        if let signingIn { return try await signingIn.value }
        let task = Task { try await self.performSignIn() }
        signingIn = task
        defer { signingIn = nil }
        return try await task.value
    }

    private func performSignIn() async throws -> SeerrUser {
        guard let target else { throw SeerrError.notConnected }
        switch target.auth {
        case .plex:
            guard let token = plexToken() else { throw SeerrError.signedOut }
            jar[Self.sessionCookie] = nil
            let (data, _) = try await perform(.signInWithPlex(token: token), allowReauth: false)
            if let session = jar[Self.sessionCookie] { vault.save(target.sessionKey, session) }
            return try decode(SeerrUser.self, from: data, endpoint: .signInWithPlex(token: ""))
        case .apiKey:
            do {
                let (data, _) = try await perform(.me, allowReauth: false)
                return try decode(SeerrUser.self, from: data, endpoint: .me)
            } catch SeerrError.notAllowed, SeerrError.signedOut {
                throw SeerrError.invalidAPIKey
            }
        }
    }

    package func send<T: Decodable & Sendable>(_ endpoint: SeerrEndpoint, as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await perform(endpoint, allowReauth: true)
        return try decode(T.self, from: data, endpoint: endpoint)
    }

    package func sendVoid(_ endpoint: SeerrEndpoint) async throws {
        _ = try await perform(endpoint, allowReauth: true)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: SeerrEndpoint) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            MidgarLog.error("Seerr \(endpoint.path) answered in a shape Crucible can't read: \(error)", category: .seerr)
            throw SeerrError.decoding
        }
    }

    private func perform(_ endpoint: SeerrEndpoint, allowReauth: Bool, answeredCSRF: Bool = false) async throws -> (Data, Int) {
        guard let target, let url = endpoint.url(base: target.address) else { throw SeerrError.notConnected }
        let (data, response) = try await transport.send(request(for: endpoint, url: url, target: target))
        absorbCookies(from: response, url: url)
        let code = response.statusCode
        if code == 403, !answeredCSRF, Self.isCSRFRefusal(data) {
            try await fetchCSRFToken(target: target)
            return try await perform(endpoint, allowReauth: allowReauth, answeredCSRF: true)
        }
        if (code == 401 || code == 403), allowReauth, !endpoint.isPublic, target.auth == .plex {
            MidgarLog.notice("Seerr refused \(endpoint.path) (\(code)); signing in again", category: .seerr)
            do {
                try await signIn()
            } catch SeerrError.accessDenied, SeerrError.signedOut {
                throw SeerrError.signedOut
            }
            return try await perform(endpoint, allowReauth: false, answeredCSRF: answeredCSRF)
        }
        if let error = SeerrError.status(code, data: data, endpoint: endpoint) {
            if target.auth == .apiKey, code == 401 || (code == 403 && endpoint == .me) { throw SeerrError.invalidAPIKey }
            if code == 401 || code == 403 { MidgarLog.notice("Seerr refused \(endpoint.path): \(code)", category: .seerr) }
            throw error
        }
        return (data, code)
    }

    private func request(for endpoint: SeerrEndpoint, url: URL, target: SeerrTarget) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if target.auth == .apiKey, let key = vault.load(target.apiKeyKey) {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
        if !jar.isEmpty {
            request.setValue(jar.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        if let csrf = jar[Self.csrfCookie] {
            request.setValue(csrf.removingPercentEncoding ?? csrf, forHTTPHeaderField: "X-XSRF-TOKEN")
        }
        return request
    }

    private func absorbCookies(from response: HTTPURLResponse, url: URL) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            jar[cookie.name] = cookie.value
        }
    }

    /// Seerr with cross-site protection on hands out its token on any answer; a status call collects it.
    private func fetchCSRFToken(target: SeerrTarget) async throws {
        guard let url = SeerrEndpoint.status.url(base: target.address) else { return }
        let (_, response) = try await transport.send(request(for: .status, url: url, target: target))
        absorbCookies(from: response, url: url)
        MidgarLog.notice("Seerr asked for its cross-site token", category: .seerr)
    }

    static func isCSRFRefusal(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8)?.lowercased().contains("csrf") == true
    }
}

extension MidgarLog.Category {
    package static let seerr = MidgarLog.Category("seerr")
}
