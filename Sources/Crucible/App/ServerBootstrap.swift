import Foundation

struct PlexConnection: Sendable {
    let serverURI: URL
    let serverName: String
    let machineIdentifier: String
    let authToken: String
    let clientIdentifier: String
    /// Every advertised/manual route to this server, best-first. Used to self-heal when the
    /// pinned `serverURI` stops working (stale plex.direct cert, moved network, dead relay).
    let candidateURIs: [URL]

    init(serverURI: URL, serverName: String, machineIdentifier: String, authToken: String, clientIdentifier: String, candidateURIs: [URL]? = nil) {
        self.serverURI = serverURI
        self.serverName = serverName
        self.machineIdentifier = machineIdentifier
        self.authToken = authToken
        self.clientIdentifier = clientIdentifier
        self.candidateURIs = candidateURIs ?? [serverURI]
    }
}

enum ServerBootstrap {
    private static let serverURIKey = "plex_server_uri"
    private static let serverNameKey = "plex_server_name"
    private static let machineIdKey = "plex_machine_id"
    private static let authTokenKey = "plex_auth_token"
    private static let candidateURIsKey = "plex_candidate_uris"

    static func connection() -> PlexConnection? {
        guard let token = KeychainHelper.load(key: authTokenKey),
              let uriString = UserDefaults.standard.string(forKey: serverURIKey),
              let uri = URL(string: uriString),
              let machineId = UserDefaults.standard.string(forKey: machineIdKey)
        else { return nil }
        let name = UserDefaults.standard.string(forKey: serverNameKey) ?? "Plex Server"
        let candidates = UserDefaults.standard.stringArray(forKey: candidateURIsKey)?
            .compactMap(URL.init(string:)) ?? []
        let ordered = [uri] + candidates.filter { $0 != uri }
        return PlexConnection(
            serverURI: uri,
            serverName: name,
            machineIdentifier: machineId,
            authToken: token,
            clientIdentifier: PlexHeaders.clientIdentifier,
            candidateURIs: ordered
        )
    }

    static var isAuthenticated: Bool {
        KeychainHelper.load(key: authTokenKey) != nil
    }

    static func saveToken(_ token: String) {
        KeychainHelper.save(key: authTokenKey, value: token)
    }

    static func saveServer(uri: URL, name: String, machineIdentifier: String, candidates: [URL] = []) {
        UserDefaults.standard.set(uri.absoluteString, forKey: serverURIKey)
        UserDefaults.standard.set(name, forKey: serverNameKey)
        UserDefaults.standard.set(machineIdentifier, forKey: machineIdKey)
        let stored = [uri] + candidates.filter { $0 != uri }
        UserDefaults.standard.set(stored.map(\.absoluteString), forKey: candidateURIsKey)
    }

    static func clear() {
        KeychainHelper.delete(key: authTokenKey)
        UserDefaults.standard.removeObject(forKey: serverURIKey)
        UserDefaults.standard.removeObject(forKey: serverNameKey)
        UserDefaults.standard.removeObject(forKey: machineIdKey)
        UserDefaults.standard.removeObject(forKey: candidateURIsKey)
    }

    /// Rewrites the pinned URI after a successful failover, keeping the full candidate list.
    static func repin(uri: URL) {
        guard var candidates = UserDefaults.standard.stringArray(forKey: candidateURIsKey)?.compactMap(URL.init(string:)) else {
            saveServer(uri: uri, name: UserDefaults.standard.string(forKey: serverNameKey) ?? "Plex Server", machineIdentifier: UserDefaults.standard.string(forKey: machineIdKey) ?? "")
            return
        }
        candidates.removeAll { $0 == uri }
        UserDefaults.standard.set(uri.absoluteString, forKey: serverURIKey)
        UserDefaults.standard.set(([uri] + candidates).map(\.absoluteString), forKey: candidateURIsKey)
    }
}
