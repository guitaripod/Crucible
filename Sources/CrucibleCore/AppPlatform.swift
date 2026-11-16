import Foundation

package enum AppPlatform {
    package static var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    package static var isLinux: Bool {
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }

    package static var plexName: String {
        isLinux ? "Linux" : isTV ? "tvOS" : "iOS"
    }

    /// The server's own client profile a converted stream starts from where it has none for `plexName`: Plex Media Server
    /// refuses a stream for platform Linux with 400 (no matching profile), so Linux names the empty Generic profile, which the
    /// stream's `X-Plex-Client-Profile-Extra` fills with everything it takes.
    package static var plexProfileName: String? {
        isLinux ? "Generic" : nil
    }

    package static var fallbackDeviceName: String {
        isLinux ? "Linux" : isTV ? "Apple TV" : "iPhone"
    }

    package static var persistentDirectory: URL {
        #if os(Linux)
        return xdgDirectory("XDG_DATA_HOME", fallback: ".local/share")
        #else
        let domain: FileManager.SearchPathDirectory = isTV ? .cachesDirectory : .applicationSupportDirectory
        return (try? FileManager.default.url(for: domain, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        #endif
    }

    /// Where re-fetchable data goes (artwork): `$XDG_CACHE_HOME/crucible` on Linux, Caches on Apple platforms.
    package static var cachesDirectory: URL {
        #if os(Linux)
        return xdgDirectory("XDG_CACHE_HOME", fallback: ".cache")
        #else
        return (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        #endif
    }

    package static var logsDirectory: URL {
        #if os(Linux)
        return xdgDirectory("XDG_STATE_HOME", fallback: ".local/state")
        #else
        let domain: FileManager.SearchPathDirectory = isTV ? .cachesDirectory : .libraryDirectory
        guard let base = try? FileManager.default.url(for: domain, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return FileManager.default.temporaryDirectory
        }
        return base.appendingPathComponent("Logs", isDirectory: true)
        #endif
    }

    #if os(Linux)
    /// `$variable/crucible`, or `~/fallback/crucible` when the variable is unset, created on first use.
    private static func xdgDirectory(_ variable: String, fallback: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback, isDirectory: true)
        let directory = base.appendingPathComponent("crucible", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    #endif
}
