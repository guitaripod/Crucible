import Foundation

struct PlexConnection: Sendable {
    let serverURI: URL
    let serverName: String
    let machineIdentifier: String
    let authToken: String
    let clientIdentifier: String
}

enum ServerBootstrap {
    private static let serverURIKey = "plex_server_uri"
    private static let serverNameKey = "plex_server_name"
    private static let machineIdKey = "plex_machine_id"
    private static let authTokenKey = "plex_auth_token"

    static func connection() -> PlexConnection? {
        guard let token = KeychainHelper.load(key: authTokenKey),
              let uriString = UserDefaults.standard.string(forKey: serverURIKey),
              let uri = URL(string: uriString),
              let machineId = UserDefaults.standard.string(forKey: machineIdKey)
        else { return nil }
        let name = UserDefaults.standard.string(forKey: serverNameKey) ?? "Plex Server"
        return PlexConnection(
            serverURI: uri,
            serverName: name,
            machineIdentifier: machineId,
            authToken: token,
            clientIdentifier: PlexHeaders.clientIdentifier
        )
    }

    static var isAuthenticated: Bool {
        KeychainHelper.load(key: authTokenKey) != nil
    }

    static func saveToken(_ token: String) {
        KeychainHelper.save(key: authTokenKey, value: token)
    }

    static func saveServer(uri: URL, name: String, machineIdentifier: String) {
        UserDefaults.standard.set(uri.absoluteString, forKey: serverURIKey)
        UserDefaults.standard.set(name, forKey: serverNameKey)
        UserDefaults.standard.set(machineIdentifier, forKey: machineIdKey)
    }

    static func clear() {
        KeychainHelper.delete(key: authTokenKey)
        UserDefaults.standard.removeObject(forKey: serverURIKey)
        UserDefaults.standard.removeObject(forKey: serverNameKey)
        UserDefaults.standard.removeObject(forKey: machineIdKey)
    }
}
