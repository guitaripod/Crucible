import Foundation

package enum PlexHeaders: Sendable {
    private static let clientIdentifierKey = "plex_client_id"

    package static var clientIdentifier: String {
        if let existing = KeychainHelper.load(key: clientIdentifierKey) {
            return existing
        }
        let id = UUID().uuidString
        KeychainHelper.save(key: clientIdentifierKey, value: id)
        return id
    }

    package static func allHeaders(token: String?) -> [String: String] {
        var headers: [String: String] = [
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": "Crucible",
            "X-Plex-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "X-Plex-Platform": AppPlatform.plexName,
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
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? AppPlatform.fallbackDeviceName
            }
        }
    }
}
