import Foundation
import os

/// How big subtitles are drawn, as a percentage of the standard size: the server draws a burned-in subtitle at this size and
/// the player scales the ones it draws itself.
package enum SubtitleSize: Int, CaseIterable, Sendable {
    case small = 75
    case standard = 100
    case large = 130
    case extraLarge = 160

    package var title: String {
        switch self {
        case .small: return String(localized: "Small", comment: "Subtitle size option")
        case .standard: return String(localized: "Standard", comment: "Subtitle size option")
        case .large: return String(localized: "Large", comment: "Subtitle size option")
        case .extraLarge: return String(localized: "Extra Large", comment: "Subtitle size option")
        }
    }
}

extension Preferences {
    private static let remoteQualityKey = "streamingQuality.remote"
    private static let cellularQualityKey = "streamingQuality.cellular"
    private static let subtitleSizeKey = "subtitles.size"
    private static let upNextCountdownKey = "upNext.countdown"

    /// The stored value meaning "the same as the setting above it".
    package static let sameQuality = -1
    package static let upNextCountdownChoices = [5, 10, 15, 20, 30]

    /// Quality away from home (a remote or relayed connection); nil follows the quality at home.
    package static var remoteQuality: Quality? {
        get { storedQuality(remoteQualityKey) }
        set { UserDefaults.standard.set(newValue?.rawValue ?? sameQuality, forKey: remoteQualityKey) }
    }

    /// Quality on a cellular connection; nil follows the quality away from home.
    package static var cellularQuality: Quality? {
        get { storedQuality(cellularQualityKey) }
        set { UserDefaults.standard.set(newValue?.rawValue ?? sameQuality, forKey: cellularQualityKey) }
    }

    package static var subtitleSize: SubtitleSize {
        get { SubtitleSize(rawValue: UserDefaults.standard.integer(forKey: subtitleSizeKey)) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: subtitleSizeKey) }
    }

    /// How long the Up Next card counts down before the next episode starts.
    package static var upNextCountdown: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: upNextCountdownKey)
            return upNextCountdownChoices.contains(stored) ? stored : 10
        }
        set { UserDefaults.standard.set(upNextCountdownChoices.contains(newValue) ? newValue : 10, forKey: upNextCountdownKey) }
    }

    private static func storedQuality(_ key: String) -> Quality? {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Int, stored != sameQuality else { return nil }
        return Quality(rawValue: stored)
    }
}

/// Whether the device is on a cellular connection right now, kept current by the player module's path monitor so the
/// stream resolver, which has no access to the network framework, can pick the cellular quality.
package enum NetworkConditions {
    private static let cellular = OSAllocatedUnfairLock(initialState: false)

    package static var isCellular: Bool {
        get { cellular.withLock { $0 } }
        set { cellular.withLock { $0 = newValue } }
    }
}

/// The quality a stream is asked for: at home the home quality, away from home the away quality, and on cellular the
/// cellular one, each falling back to the one before it when set to match.
package enum QualityPolicy {
    package static func quality(route: HomeServerRoute, isCellular: Bool) -> Preferences.Quality {
        let home = Preferences.streamingQuality
        let away = Preferences.remoteQuality ?? home
        if isCellular { return Preferences.cellularQuality ?? away }
        return route == .local ? home : away
    }

    package static func current(for baseURL: URL) -> Preferences.Quality {
        quality(route: HomeServerRoute.classify(baseURL), isCellular: NetworkConditions.isCellular)
    }
}
