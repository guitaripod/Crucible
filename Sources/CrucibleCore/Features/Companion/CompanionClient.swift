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
    case refused(String)
    case failed(String)

    package var message: String {
        switch self {
        case .unreachable: String(localized: "Crucible Server isn't answering. Check that the computer with Plex is on and on this network or your tailnet.", comment: "Crucible Server error")
        case .wrongServer: String(localized: "Another computer answered at that address, so Crucible didn't pair with it.", comment: "Crucible Server error when the certificate or proof does not match")
        case .codeRefused: String(localized: "That pairing code is wrong or has expired. Run crucible-server pair for a new one.", comment: "Crucible Server error")
        case .notPaired: String(localized: "This device isn't paired with Crucible Server any more. Pair it again.", comment: "Crucible Server error")
        case .noModel: String(localized: "Crucible Server has no model set up yet.", comment: "Crucible Server error")
        case .busy: String(localized: "Crucible Server is still writing your last request.", comment: "Crucible Server error")
        case .refused(let message), .failed(let message): message
        }
    }
}

/// Accepts the server's self-made certificate only by its SHA-256 fingerprint: the one pinned at pairing, or, while
/// pairing, whatever it is, recorded so the HMAC proofs can be bound to it.
private final class FingerprintTrust: NSObject, URLSessionDelegate, Sendable {
    let expected: String?
    private let seen = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(expected: String?) {
        self.expected = expected
    }

    var fingerprint: String? { seen.withLock { $0 } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return (.cancelAuthenticationChallenge, nil) }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        seen.withLock { $0 = fingerprint }
        if let expected, expected != fingerprint { return (.cancelAuthenticationChallenge, nil) }
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
            throw trust.expected != nil && trust.fingerprint != nil && trust.fingerprint != trust.expected ? .wrongServer : .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            switch (status, detail?.code) {
            case (_, "pairing_refused"): throw .codeRefused
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

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", name, version, fingerprint, brain
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

    /// Tries each of the invite's hosts until one answers, checks that the server proves it saw the same secret over
    /// the certificate this device sees, proves it back, and returns the pairing to keep.
    package static func pair(_ invite: CompanionInvite, deviceName: String, platform: String, machineIdentifier: String?) async throws(CompanionError) -> CompanionServer {
        var failure = CompanionError.unreachable
        for host in invite.hosts {
            guard let connection = Connection(host: host, expected: invite.fingerprint, timeout: 8) else { continue }
            defer { connection.session.invalidateAndCancel() }
            do throws(CompanionError) {
                let _: CompanionHello = try await connection.send("GET", "hello", body: Nothing?.none)
                guard let seen = connection.trust.fingerprint else { throw CompanionError.wrongServer }
                let deviceNonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                let began: Began = try await connection.send("POST", "pair", body: Begin(id: invite.secretID, deviceNonce: deviceNonce))
                let expected = CompanionProof.server(secret: invite.secret, fingerprint: seen, deviceNonce: deviceNonce, serverNonce: began.serverNonce)
                guard CompanionProof.matches(expected, began.proof) else { throw CompanionError.wrongServer }
                let proof = CompanionProof.device(secret: invite.secret, fingerprint: seen, deviceNonce: deviceNonce, serverNonce: began.serverNonce)
                let finished: Finished = try await connection.send("POST", "pair/confirm", body: Finish(id: invite.secretID, proof: proof, name: deviceName, platform: platform))
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
                if error == .codeRefused || error == .wrongServer { throw error }
                failure = error
            }
        }
        throw failure
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
                if error != .unreachable { throw error }
                failure = error
            }
        }
        throw failure
    }

    private struct BrainAnswer: Decodable, Sendable {
        let model: String?
        let reachable: Bool
    }

    /// The model the server writes with, and whether it answers right now.
    package func brain() async throws(CompanionError) -> (model: String?, reachable: Bool) {
        let answer: BrainAnswer = try await onFirstHost(timeout: 15) { connection throws(CompanionError) in
            try await connection.send("GET", "brain", body: Nothing?.none, headers: headers)
        }
        return (answer.model, answer.reachable)
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
