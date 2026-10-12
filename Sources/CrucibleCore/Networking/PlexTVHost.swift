import Foundation

/// The plex.tv hosts the app talks to. Debug builds can point both at a local mock through the
/// `CRUCIBLE_PLEXTV` environment variable, and the demo points them at its own stand-in while it runs; otherwise the real hosts.
package enum PlexTVHost {
    package static let environmentVariable = "CRUCIBLE_PLEXTV"

    static var clients: URL { override ?? mockURL ?? URL(string: "https://clients.plex.tv")! }
    static var account: URL { override ?? mockURL ?? URL(string: "https://plex.tv")! }

    private static let mockURL = parseOverride(in: ProcessInfo.processInfo.environment, allowed: isDebugBuild)

    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var overrideURL: URL?

    private static var override: URL? {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        return overrideURL
    }

    /// Points both hosts at the demo's plex.tv stand-in while the demo runs, and back at the real ones afterwards.
    package static func setOverride(_ url: URL?) {
        overrideLock.lock()
        overrideURL = url
        overrideLock.unlock()
    }

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
