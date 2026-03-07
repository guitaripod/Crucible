import Foundation

enum ServerBootstrap {
    private static let key = "server_url"

    static func savedServerURL() -> URL? {
        guard let string = UserDefaults.standard.string(forKey: key) else { return nil }
        return URL(string: string)
    }

    static func save(serverURL: URL) {
        UserDefaults.standard.set(serverURL.absoluteString, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
