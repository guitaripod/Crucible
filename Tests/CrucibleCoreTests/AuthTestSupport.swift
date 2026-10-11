import Foundation
@testable import CrucibleCore

enum AuthFixtures {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func pin(id: Int = 1, code: String = "ABCD", token: String? = nil, expiresIn: Int? = 900) -> PlexPin {
        let tokenJSON = token.map { "\"\($0)\"" } ?? "null"
        let expiryJSON = expiresIn.map(String.init) ?? "null"
        return decode(PlexPin.self, #"{"id": \#(id), "code": "\#(code)", "authToken": \#(tokenJSON), "expiresIn": \#(expiryJSON)}"#)
    }

    static func resource(
        name: String,
        id: String,
        provides: String = "server",
        owned: Bool = true,
        online: Bool = true,
        uris: [String]
    ) -> PlexResource {
        let connections = uris.map { uri in
            let url = URL(string: uri)
            let isLocal = url.map { ConnectionRoute.kind(of: $0) == .local } ?? false
            return #"{"uri": "\#(uri)", "address": "\#(url?.host ?? "")", "protocol": "http", "local": \#(isLocal), "relay": false}"#
        }
        return decode(PlexResource.self, """
        {"name": "\(name)", "provides": "\(provides)", "clientIdentifier": "\(id)", "owned": \(owned), "presence": \(online),
         "connections": [\(connections.joined(separator: ","))]}
        """)
    }

    static func choice(name: String, id: String, online: Bool = true, uris: [String]) -> ServerChoice {
        ServerChoice(resource: resource(name: name, id: id, online: online, uris: uris))
    }

    static func metadata(_ json: String) -> PlexMetadata {
        decode(PlexMetadata.self, json)
    }

    static func connection(name: String = "Marcus-PC", id: String = "m1", uri: String = "http://10.0.0.2:32400", candidates: [String] = []) -> PlexConnection {
        PlexConnection(
            serverURI: URL(string: uri)!,
            serverName: name,
            machineIdentifier: id,
            authToken: "tok",
            clientIdentifier: "client",
            candidateURIs: ([uri] + candidates).compactMap(URL.init(string:))
        )
    }
}

final class AuthLocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}

final class AuthStubClock: @unchecked Sendable {
    let start = Date(timeIntervalSince1970: 1_000_000)
    private let time: AuthLocked<Date>
    let sleeps = AuthLocked<[Duration]>([])

    init() {
        time = AuthLocked(start)
    }

    var now: Date { time.value }

    var clock: PlexPinClock {
        PlexPinClock(
            now: { [time] in time.value },
            sleep: { [time, sleeps] duration in
                try Task.checkCancellation()
                sleeps.update { $0.append(duration) }
                time.update { $0 = $0.addingTimeInterval(Double(duration.components.seconds)) }
                await Task.yield()
            }
        )
    }
}

final class AuthScriptedPins: @unchecked Sendable {
    typealias Reply = Result<PlexPin, Error>

    let created = AuthLocked<[Bool]>([])
    let checked = AuthLocked<[Int]>([])
    private let createReply: @Sendable (Bool) -> Reply
    private let checkReply: @Sendable (Int, Int) -> Reply

    init(create: @escaping @Sendable (Bool) -> Reply, check: @escaping @Sendable (Int, Int) -> Reply) {
        createReply = create
        checkReply = check
    }

    convenience init(create: Reply, checks: [Reply]) {
        let position = AuthLocked(0)
        self.init(
            create: { _ in create },
            check: { _, _ in
                var index = 0
                position.update { index = $0; $0 += 1 }
                return checks[min(index, checks.count - 1)]
            }
        )
    }

    var transport: PlexPinTransport {
        PlexPinTransport(
            create: { [self] strong in
                created.update { $0.append(strong) }
                return try createReply(strong).get()
            },
            check: { [self] id in
                var attempt = 0
                checked.update { $0.append(id); attempt = $0.filter { $0 == id }.count }
                return try checkReply(id, attempt).get()
            }
        )
    }
}

func authCollect<State: Sendable>(_ stream: AsyncStream<State>) async -> [State] {
    var states: [State] = []
    for await state in stream { states.append(state) }
    return states
}
