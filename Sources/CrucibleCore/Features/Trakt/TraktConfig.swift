import Foundation

/// Supplies the Client ID of Crucible's Trakt app. The conformance lives in `TraktClientID.swift`, which is kept out of the
/// public repository: a build without it has no Trakt integration, and a fork registers its own Trakt app instead of
/// borrowing Crucible's.
protocol TraktClientIDProviding {
    static var bundledClientID: String { get }
}

/// Where Crucible reaches Trakt and how it introduces itself.
package enum TraktConfig {
    package static let environmentVariable = "CRUCIBLE_TRAKT"

    /// The Client ID requests carry: this build's own, or a stand-in while the demo or a debug mock answers instead of Trakt.
    package static var clientID: String? {
        if isStandIn { return "crucible-demo" }
        return shippedClientID
    }

    /// Whether the demo or a debug mock answers instead of Trakt, so nothing it holds is ever taken for the viewer's real link.
    package static var isStandIn: Bool { override != nil || mockURL != nil }

    /// Whether this build can talk to Trakt at all.
    package static var isAvailable: Bool { clientID != nil }

    /// The API host.
    package static var apiURL: URL { override ?? mockURL ?? URL(string: "https://api.trakt.tv")! }

    /// The host every sign-in uses; Trakt requires it for all login flows from 2027-02-01.
    package static var authURL: URL { override ?? mockURL ?? URL(string: "https://auth.trakt.tv")! }

    /// The page a viewer approves a device code on.
    package static var activationURL: URL { authURL.appendingPathComponent("activate") }

    package static var userAgent: String { "Crucible/\(AppInfo.versionText) (\(AppPlatform.isTV ? "tvOS" : "iOS"))" }

    private static var shippedClientID: String? {
        let provider = TraktConfig.self as Any.Type as? TraktClientIDProviding.Type
        guard let id = provider?.bundledClientID.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id
    }

    private static let mockURL = parseOverride(ProcessInfo.processInfo.environment[environmentVariable], allowed: isDebugBuild)

    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var overrideURL: URL?

    private static var override: URL? {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        return overrideURL
    }

    /// Points Trakt at the demo's stand-in while the demo runs, and back at Trakt afterwards.
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
    static func parseOverride(_ raw: String?, allowed: Bool) -> URL? {
        guard allowed,
              let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
