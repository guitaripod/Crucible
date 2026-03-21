import Foundation

enum PlexHeaders: Sendable {
    private static let clientIdentifierKey = "plex_client_id"

    static var clientIdentifier: String {
        if let existing = KeychainHelper.load(key: clientIdentifierKey) {
            return existing
        }
        let id = UUID().uuidString
        KeychainHelper.save(key: clientIdentifierKey, value: id)
        return id
    }

    static func allHeaders(token: String?) -> [String: String] {
        var headers: [String: String] = [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": "Crucible",
            "X-Plex-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "X-Plex-Platform": "iOS",
            "X-Plex-Platform-Version": ProcessInfo.processInfo.operatingSystemVersionString,
            "X-Plex-Device": deviceModel(),
            "Accept": "application/json",
        ]
        if let token {
            headers["X-Plex-Token"] = token
        }
        return headers
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "iPhone"
            }
        }
    }
}
