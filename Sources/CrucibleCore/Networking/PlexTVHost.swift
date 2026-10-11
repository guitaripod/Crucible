import Foundation

/// The plex.tv hosts the app talks to. Debug builds can point both at a local mock through the
/// `CRUCIBLE_PLEXTV` environment variable; release builds always use the real hosts.
package enum PlexTVHost {
    package static let environmentVariable = "CRUCIBLE_PLEXTV"

    static let clients = mockURL ?? URL(string: "https://clients.plex.tv")!
    static let account = mockURL ?? URL(string: "https://plex.tv")!

    private static let mockURL = parseOverride(in: ProcessInfo.processInfo.environment, allowed: isDebugBuild)

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The overriding base URL when one is allowed and well formed: an http(s) URL with a host.
    static func parseOverride(in environment: [String: String], allowed: Bool) -> URL? {
        guard allowed,
              let raw = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
