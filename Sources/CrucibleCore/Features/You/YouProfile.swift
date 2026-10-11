import Foundation

/// How a connection indicator should be coloured, independent of any UI toolkit.
package enum ConnectionTone: Equatable, Sendable {
    case neutral
    case ok
    case failure
}

extension PlexAccountName {
    package static let fallbackName = "Plex User"

    /// The display name `refresh(token:)` stored, or "Plex User" before it has run or when it came back blank.
    package static var stored: String {
        let value = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return fallbackName }
        return value
    }
}

extension YouConnectionState {
    /// The route name for the Server & Connection row, nil while the first probe is running.
    package var routeSummary: String? {
        switch self {
        case .connecting: return nil
        case .reachable(let route, _): return route.rawValue
        case .unreachable: return "Unreachable"
        }
    }
}

/// What the profile panel at the top of the You tab shows: the account and one status line for the server.
package struct YouProfile: Equatable, Sendable {
    package let name: String
    package let statusText: String
    package let tone: ConnectionTone

    package static var currentServerName: String {
        ServerBootstrap.connection()?.serverName ?? "Plex Server"
    }

    package static func make(accountName: String, serverName: String = currentServerName, state: YouConnectionState) -> YouProfile {
        switch state {
        case .connecting:
            return YouProfile(name: accountName, statusText: "\(serverName) · Connecting…", tone: .neutral)
        case .reachable(let route, let latency):
            return YouProfile(name: accountName, statusText: "\(serverName) · \(route.rawValue) · \(latency) ms", tone: .ok)
        case .unreachable:
            return YouProfile(name: accountName, statusText: "\(serverName) · Unreachable", tone: .failure)
        }
    }
}

/// The subtitle under "Watch History": the title of the most recent play and when it happened.
package enum YouHistoryHeadline {
    package static func latest(api: APIClient) async -> String? {
        guard let container = try? await api.requestContainer(.history(start: 0, size: 1)),
              let entry = container.Metadata?.first else { return nil }
        return headline(title: entry.title, grandparentTitle: entry.grandparentTitle, viewedAt: entry.lastViewedAt ?? entry.viewedAt)
    }

    static func headline(title: String, grandparentTitle: String?, viewedAt: Int?) -> String? {
        let name = grandparentTitle ?? title
        guard !name.isEmpty else { return nil }
        guard let when = Formatters.unixRelativeDate(viewedAt) else { return name }
        return "\(name) · \(when)"
    }
}
