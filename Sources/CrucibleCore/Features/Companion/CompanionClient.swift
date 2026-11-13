import CryptoKit
import Foundation
import os

/// A paired Crucible Server, as this device keeps it in the Keychain: the token it was given and the fingerprint of
/// the certificate it pinned.
package struct CompanionServer: Codable, Equatable, Sendable {
    package var name: String
    package var hosts: [String]
    package var fingerprint: String
    package var token: String
    package var deviceID: String
    package var plexMachineIdentifier: String?
}

/// What a Crucible Server says about its model: its name, whether it answers right now, and the host it is at when
/// the owner chose a hosted service outside their own network. A server from before hosted models says no host.
package struct CompanionBrain: Decodable, Equatable, Sendable {
    package var model: String?
    package var reachable: Bool
    package var outside: String?

    package init(model: String?, reachable: Bool, outside: String? = nil) {
        self.model = model
        self.reachable = reachable
        self.outside = outside
    }
}

/// Where the pairing is kept, one per device, tied to the Plex server it was made for.
package enum CompanionStore {
    private static let key = "crucible_server"

    package static func load() -> CompanionServer? {
        guard let json = KeychainHelper.load(key: key) else { return nil }
        return try? JSONDecoder().decode(CompanionServer.self, from: Data(json.utf8))
    }

    /// The pairing, when it belongs to the Plex server Crucible is connected to.
    package static func current(machineIdentifier: String? = ServerBootstrap.connection()?.machineIdentifier) -> CompanionServer? {
        guard let server = load() else { return nil }
        guard let paired = server.plexMachineIdentifier, let machineIdentifier else { return server }
        return paired == machineIdentifier ? server : nil
    }

    package static func save(_ server: CompanionServer) {
        guard let data = try? JSONEncoder().encode(server), let json = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(key: key, value: json)
    }

    package static func forget() {
        KeychainHelper.delete(key: key)
    }
}

/// Why talking to Crucible Server failed, in words a person can act on.
package enum CompanionError: Error, Equatable, Sendable {
    case unreachable
    case wrongServer
    case codeRefused
    case notPaired
    case noModel
    case busy
    case otherPlexServer
    case pairingUnconfirmed
    case notNearby
    case refused(String)
    case failed(String)

    /// How much an error says about why pairing failed, so trying several addresses reports the most telling one.
    var weight: Int {
        switch self {
        case .unreachable: 0
        case .wrongServer: 1
        default: 2
        }
    }

    package var message: String {
        switch self {
        case .unreachable: String(localized: "Crucible Server isn't answering. Check that the computer with Plex is on and on this network or your tailnet.", comment: "Crucible Server error")
        case .wrongServer: String(localized: "Another computer answered at that address, so Crucible didn't pair with it.", comment: "Crucible Server error when the certificate or proof does not match")
        case .codeRefused: String(localized: "That pairing code is wrong or has expired. Run crucible-server pair for a new one.", comment: "Crucible Server error")
        case .notPaired: String(localized: "This device isn't paired with Crucible Server any more. Pair it again.", comment: "Crucible Server error")
        case .noModel: String(localized: "Crucible Server has no model set up yet.", comment: "Crucible Server error")
        case .busy: String(localized: "Crucible Server is still writing your last request.", comment: "Crucible Server error")
        case .otherPlexServer: String(localized: "That Crucible Server runs beside a different Plex server than the one Crucible is using.", comment: "Crucible Server error when the server belongs to another Plex server")
        case .pairingUnconfirmed: String(localized: "Crucible Server may have paired this device without answering. Run crucible-server devices on the computer with Plex, unpair any extra entry, then pair again with a new code.", comment: "Crucible Server error when the last pairing step got no answer")
        case .notNearby: String(localized: "Crucible Server isn't at an address on your home network or tailnet, so an Apple TV can't pair through this iPhone. Enter a code from crucible-server pair on the Apple TV instead.", comment: "Crucible Server error when an iPhone cannot hand a pairing to a nearby Apple TV")
        case .refused(let message), .failed(let message): message
        }
    }
}

/// Accepts the server's self-made certificate only by its SHA-256 fingerprint: the one pinned at pairing, or, while
/// pairing, the first one this connection sees, recorded so the HMAC proofs are bound to it and every later request of
/// the pairing goes to the same certificate.
private final class FingerprintTrust: NSObject, URLSessionDelegate, Sendable {
    let expected: String?
    private let seen = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let rejection = OSAllocatedUnfairLock(initialState: false)

    init(expected: String?) {
        self.expected = expected
    }

    var fingerprint: String? { seen.withLock { $0 } }

    /// Whether a certificate other than the pinned or first one answered.
    var rejected: Bool { rejection.withLock { $0 } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return (.cancelAuthenticationChallenge, nil) }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        let first = seen.withLock { seen in
            if seen == nil { seen = fingerprint }
            return seen
        }
        guard (expected ?? first) == fingerprint else {
            rejection.withLock { $0 = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

private struct ErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }

    let error: Detail
}

/// One HTTPS session to one host of the server.
private struct Connection {
    let base: URL
    let session: URLSession
    let trust: FingerprintTrust

    init?(host: String, expected: String?, timeout: TimeInterval) {
        guard let base = URL(string: "https://\(host)/crucible/v1/") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let trust = FingerprintTrust(expected: expected)
        self.base = base
        self.trust = trust
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    func send<Body: Encodable, Answer: Decodable>(_ method: String, _ path: String, body: Body?, headers: [String: String] = [:]) async throws(CompanionError) -> Answer {
        var request = URLRequest(url: URL(string: path, relativeTo: base)?.absoluteURL ?? base)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Bundle.main.preferredLocalizations.first ?? "en", forHTTPHeaderField: "Accept-Language")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = try? JSONEncoder().encode(body) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw trust.rejected ? .wrongServer : .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            switch (status, detail?.code) {
            case (_, "pairing_refused"): throw .codeRefused
            case (_, "no_plex_token"), (_, "too_many_pairings"): throw .refused(detail?.message ?? HTTPURLResponse.localizedString(forStatusCode: status))
            case (401, _): throw .notPaired
            case (503, "no_model"): throw .noModel
            case (429, _): throw .busy
            default: throw .refused(detail?.message ?? HTTPURLResponse.localizedString(forStatusCode: status))
            }
        }
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw .failed(String(localized: "Crucible Server sent an answer this version of Crucible doesn't understand. Update both.", comment: "Crucible Server error"))
        }
    }
}

private struct Nothing: Codable {}

/// What `/hello` says about the server.
package struct CompanionHello: Decodable, Sendable {
    package let protocolVersion: Int
    package let name: String
    package let version: String
    package let fingerprint: String
    package let brain: Bool
    package let plexMachineIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", name, version, fingerprint, brain, plexMachineIdentifier
    }
}

/// Pairing this device with a Crucible Server from an invite.
package enum CompanionPairing {
    private struct Begin: Encodable {
        let id: String
        let deviceNonce: String
    }

    private struct Began: Decodable {
        let serverNonce: String
        let proof: String
    }

    private struct Finish: Encodable {
        let id: String
        let proof: String
        let name: String
        let platform: String
    }

    private struct Finished: Decodable {
        let deviceId: String
        let token: String
        let name: String
    }

    /// Tries each of the invite's hosts until one answers, checks that the server says it runs beside this Plex server
    /// and proves it saw the same secret over the certificate this device sees, proves it back, and returns the pairing
    /// to keep. Pass `plexToken` only for a secret another device handed on, which the server admits by its owner's
    /// policy; a secret from the owner's terminal needs no Plex token, so a link that names someone else's computer
    /// never receives one while pairing.
    package static func pair(_ invite: CompanionInvite, deviceName: String, platform: String, machineIdentifier: String?, plexToken: String? = nil) async throws(CompanionError) -> CompanionServer {
        var failure = CompanionError.unreachable
        for host in invite.hosts {
            guard let connection = Connection(host: host, expected: invite.fingerprint, timeout: 8) else { continue }
            defer { connection.session.invalidateAndCancel() }
            do throws(CompanionError) {
                let hello: CompanionHello = try await connection.send("GET", "hello", body: Nothing?.none)
                guard let seen = connection.trust.fingerprint else { throw CompanionError.wrongServer }
                if let machineIdentifier, hello.plexMachineIdentifier != machineIdentifier {
                    throw CompanionError.otherPlexServer
                }
                let finished = try await exchange(invite, on: connection, fingerprint: seen, deviceName: deviceName, platform: platform, plexToken: plexToken)
                let others: [String] = invite.hosts.filter { $0 != host }
                return CompanionServer(
                    name: finished.name,
                    hosts: [host] + others,
                    fingerprint: seen,
                    token: finished.token,
                    deviceID: finished.deviceId,
                    plexMachineIdentifier: machineIdentifier
                )
            } catch {
                if error == .codeRefused || error == .pairingUnconfirmed || error == .otherPlexServer { throw error }
                if error.weight > failure.weight { failure = error }
            }
        }
        throw failure
    }

    /// The two proofs over `connection`. When the last step goes unanswered, or its answer cannot be read, the server
    /// is asked once more: a secret it still holds means the step never landed, so the exchange simply runs again; a
    /// secret it no longer knows may have paired this device, which is reported rather than retried as a wrong code.
    private static func exchange(_ invite: CompanionInvite, on connection: Connection, fingerprint: String, deviceName: String, platform: String, plexToken: String?) async throws(CompanionError) -> Finished {
        var unanswered = false
        while true {
            let deviceNonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let began: Began
            do throws(CompanionError) {
                began = try await connection.send("POST", "pair", body: Begin(id: invite.secretID, deviceNonce: deviceNonce))
            } catch {
                throw unanswered ? .pairingUnconfirmed : error
            }
            let expected = CompanionProof.server(secret: invite.secret, fingerprint: fingerprint, deviceNonce: deviceNonce, serverNonce: began.serverNonce)
            guard CompanionProof.matches(expected, began.proof) else { throw .wrongServer }
            let proof = CompanionProof.device(secret: invite.secret, fingerprint: fingerprint, deviceNonce: deviceNonce, serverNonce: began.serverNonce)
            do throws(CompanionError) {
                return try await connection.send("POST", "pair/confirm", body: Finish(id: invite.secretID, proof: proof, name: deviceName, platform: platform),
                                                 headers: plexToken.map { ["Crucible-Plex-Token": $0] } ?? [:])
            } catch {
                guard Self.mayHavePaired(error) else { throw error }
                guard !unanswered else { throw .pairingUnconfirmed }
                unanswered = true
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Whether a failed last step may have reached the server: it went unanswered, or its answer could not be read.
    private static func mayHavePaired(_ error: CompanionError) -> Bool {
        switch error {
        case .unreachable, .failed: true
        default: false
        }
    }

    /// Pairs with a secret this device made and showed (the Apple TV's QR code) once a paired device has handed it to the
    /// server, trying every two seconds until then. The server's proof stands in for a fingerprint: the real server
    /// learns the secret from the paired device over its pinned connection. Anyone else who saw the code and can answer
    /// at the Plex machine's address could prove it too, which is why the code is shown only while the Apple TV waits.
    package static func waitForHandOff(_ invite: CompanionInvite, deviceName: String, platform: String, machineIdentifier: String?, plexToken: String?, until deadline: Date) async throws(CompanionError) -> CompanionServer {
        var lastFailure = CompanionError.codeRefused
        while Date() < deadline, !Task.isCancelled {
            do throws(CompanionError) {
                return try await pair(invite, deviceName: deviceName, platform: platform, machineIdentifier: machineIdentifier, plexToken: plexToken)
            } catch {
                if error == .otherPlexServer || error == .pairingUnconfirmed { throw error }
                lastFailure = error
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw lastFailure
    }

    /// Where Crucible Server listens when it runs beside Plex: the Plex server's own host (a plex.direct name resolves
    /// to the same address) at the companion's port. The certificate is pinned, so the name it is reached by never matters.
    package static func hostBesidePlex(_ plexURL: URL?) -> String? {
        guard let host = plexURL?.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.contains(":") ? "[\(host)]:\(CompanionInvite.defaultPort)" : "\(host):\(CompanionInvite.defaultPort)"
    }
}

/// A Previously On, as the server wrote it.
package struct CompanionRecap: Decodable, Equatable, Sendable {
    package let text: String
    package let basedOn: [String]
    package let grounded: Bool
    package let model: String
}

/// An answer to a question asked while watching.
package struct CompanionAnswer: Decodable, Equatable, Sendable {
    package let text: String
    package let grounded: Bool
}

/// Requests to the paired server, made as the person signed in to Plex on this device.
package struct CompanionClient: Sendable {
    package let server: CompanionServer
    package let plexToken: String

    package init(server: CompanionServer, plexToken: String) {
        self.server = server
        self.plexToken = plexToken
    }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(server.token)", "Crucible-Plex-Token": plexToken]
    }

    private struct Started: Decodable {
        let id: String
    }

    private struct Collected<Result: Decodable>: Decodable {
        let status: String
        let result: Result?
        let message: String?
    }

    private struct RecapRequest: Encodable {
        let finished: [String]
        let language: String?
    }

    private struct QuestionRequest: Encodable {
        let item: String
        let playheadMs: Int
        let finished: [String]
        let question: String
        let language: String?
    }

    /// Runs `work` against the first host that answers, remembering nothing about the others.
    private func onFirstHost<Answer: Sendable>(timeout: TimeInterval, _ work: (Connection) async throws(CompanionError) -> Answer) async throws(CompanionError) -> Answer {
        var failure = CompanionError.unreachable
        for host in server.hosts {
            guard let connection = Connection(host: host, expected: server.fingerprint, timeout: timeout) else { continue }
            defer { connection.session.invalidateAndCancel() }
            do throws(CompanionError) {
                return try await work(connection)
            } catch {
                if error.weight == 2 { throw error }
                if error.weight > failure.weight { failure = error }
            }
        }
        throw failure
    }

    /// The model the server writes with, whether it answers right now, and where it is.
    package func brain() async throws(CompanionError) -> CompanionBrain {
        try await onFirstHost(timeout: 15) { connection throws(CompanionError) in
            try await connection.send("GET", "brain", body: Nothing?.none, headers: headers)
        }
    }

    private struct HandedCode: Encodable {
        let secret: String
    }

    private struct Opened: Decodable {
        let expiresIn: Int
    }

    /// Hands the server a secret another device made, so that device can pair by proving it knows it.
    package func addDevice(secret: Data) async throws(CompanionError) {
        let _: Opened = try await onFirstHost(timeout: 10) { connection throws(CompanionError) in
            try await connection.send("POST", "pair/code", body: HandedCode(secret: Base32.encode(secret)), headers: headers)
        }
    }

    /// An invite for a nearby device: a fresh secret handed to the server, with where the server answers on the home
    /// network or tailnet and the fingerprint this device pinned, so the other device pins the same certificate.
    package func inviteForNearbyDevice() async throws(CompanionError) -> CompanionInvite {
        let hosts = server.hosts.filter { CompanionInvite.isNearby($0) }
        guard !hosts.isEmpty else { throw .notNearby }
        let secret = CompanionInvite.newSecret()
        try await addDevice(secret: secret)
        return CompanionInvite(name: server.name, hosts: hosts, secret: secret, fingerprint: server.fingerprint)
    }

    /// Closes a pairing this device handed on, because the device it was for left before using it.
    package func withdraw(_ invite: CompanionInvite) async throws(CompanionError) {
        let _: Withdrawn = try await onFirstHost(timeout: 10) { connection throws(CompanionError) in
            try await connection.send("DELETE", "pair/code/\(invite.secretID)", body: Nothing?.none, headers: headers)
        }
    }

    private struct Withdrawn: Decodable {
        let withdrawn: Bool
    }

    package func hello() async throws(CompanionError) -> CompanionHello {
        try await onFirstHost(timeout: 6) { connection throws(CompanionError) in
            try await connection.send("GET", "hello", body: Nothing?.none)
        }
    }

    /// A Previously On from the episodes `finished` lists (oldest first), waiting up to two minutes for it.
    package func recap(finished: [String]) async throws(CompanionError) -> CompanionRecap {
        let language = Bundle.main.preferredLocalizations.first
        return try await onFirstHost(timeout: 35) { connection throws(CompanionError) in
            let started: Started = try await connection.send("POST", "recaps", body: RecapRequest(finished: finished, language: language), headers: headers)
            return try await collect(connection, path: "recaps/\(started.id)")
        }
    }

    /// An answer about `item` from what has been seen up to `playheadMs`.
    package func ask(item: String, playheadMs: Int, finished: [String], question: String) async throws(CompanionError) -> CompanionAnswer {
        let language = Bundle.main.preferredLocalizations.first
        return try await onFirstHost(timeout: 35) { connection throws(CompanionError) in
            let body = QuestionRequest(item: item, playheadMs: playheadMs, finished: finished, question: question, language: language)
            let started: Started = try await connection.send("POST", "questions", body: body, headers: headers)
            return try await collect(connection, path: "questions/\(started.id)")
        }
    }

    private func collect<Result: Decodable & Sendable>(_ connection: Connection, path: String) async throws(CompanionError) -> Result {
        for _ in 0..<5 {
            let collected: Collected<Result> = try await connection.send("GET", "\(path)?wait=25", body: Nothing?.none, headers: headers)
            switch collected.status {
            case "ready":
                if let result = collected.result { return result }
            case "failed":
                throw .failed(collected.message ?? "")
            default:
                continue
            }
        }
        throw .failed(String(localized: "Crucible Server took too long. Try again in a moment.", comment: "Crucible Server error"))
    }
}

/// The episodes a Previously On may draw on: the ones watched before the episode about to play, oldest first.
package enum PreviouslyOn {
    package static func finished(in episodes: [PlexMetadata], before next: PlexMetadata?) -> [String] {
        let ordered = EpisodeOrder.sorted(episodes)
        let cutoff = next.flatMap { next in ordered.firstIndex { $0.id == next.id } } ?? ordered.count
        return ordered.prefix(cutoff).filter(\.isWatched).map(\.id)
    }
}
