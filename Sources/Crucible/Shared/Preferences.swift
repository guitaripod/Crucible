import Foundation

enum Preferences {
    private static let qualityKey = "streamingQuality"
    private static let downloadQualityKey = "downloadQuality"
    private static let downloadCellularKey = "downloadOverCellular"
    private static let downloadConcurrencyKey = "downloadConcurrency"
    private static let deleteWatchedKey = "deleteWatchedDownloads"
    private static let libraryColumnsKey = "libraryColumns"
    private static let skipIntroKey = "skipIntroMode"
    private static let autoplayNextKey = "autoplayNextEpisode"
    private static let appearanceKey = "appearanceMode"
    private static let preferLocalKey = "preferLocalConnection"
    private static let allowRelayKey = "allowRelayConnection"
    private static let recentSearchesKey = "recentSearches"

    enum Quality: Int, CaseIterable, Sendable {
        case original = 0
        case high = 20000
        case medium = 8000
        case low = 3000

        var title: String {
            switch self {
            case .original: return "Original"
            case .high: return "High · 20 Mbps"
            case .medium: return "Medium · 8 Mbps"
            case .low: return "Low · 3 Mbps"
            }
        }
    }

    enum SkipIntroMode: Int, CaseIterable, Sendable {
        case button = 0
        case automatic = 1
        case off = 2

        var title: String {
            switch self {
            case .button: return "Show Button"
            case .automatic: return "Skip Automatically"
            case .off: return "Off"
            }
        }
    }

    enum Appearance: Int, CaseIterable, Sendable {
        case system = 0
        case dark = 1
        case light = 2

        var title: String {
            switch self {
            case .system: return "System"
            case .dark: return "Dark"
            case .light: return "Light"
            }
        }
    }

    static var streamingQuality: Quality {
        get { Quality(rawValue: UserDefaults.standard.integer(forKey: qualityKey)) ?? .original }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: qualityKey) }
    }

    static var downloadQuality: DownloadQuality {
        get {
            guard UserDefaults.standard.object(forKey: downloadQualityKey) != nil else { return .high }
            return DownloadQuality(rawValue: UserDefaults.standard.integer(forKey: downloadQualityKey)) ?? .high
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: downloadQualityKey) }
    }

    static var downloadOverCellular: Bool {
        get { UserDefaults.standard.bool(forKey: downloadCellularKey) }
        set { UserDefaults.standard.set(newValue, forKey: downloadCellularKey) }
    }

    static var maxConcurrentDownloads: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: downloadConcurrencyKey)
            return stored == 0 ? 3 : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: downloadConcurrencyKey) }
    }

    static var deleteWatchedDownloads: Bool {
        get { UserDefaults.standard.bool(forKey: deleteWatchedKey) }
        set { UserDefaults.standard.set(newValue, forKey: deleteWatchedKey) }
    }

    /// Poster columns in library grids on a phone: 2 (large) or 3 (default).
    static var libraryColumns: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: libraryColumnsKey)
            return stored == 2 ? 2 : 3
        }
        set { UserDefaults.standard.set(newValue == 2 ? 2 : 3, forKey: libraryColumnsKey) }
    }

    static var skipIntroMode: SkipIntroMode {
        get { SkipIntroMode(rawValue: UserDefaults.standard.integer(forKey: skipIntroKey)) ?? .button }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: skipIntroKey) }
    }

    static var autoplayNextEpisode: Bool {
        get { UserDefaults.standard.object(forKey: autoplayNextKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoplayNextKey) }
    }

    static var appearance: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.integer(forKey: appearanceKey)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }

    static var preferLocalConnection: Bool {
        get { UserDefaults.standard.object(forKey: preferLocalKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferLocalKey) }
    }

    static var allowRelayConnection: Bool {
        get { UserDefaults.standard.object(forKey: allowRelayKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: allowRelayKey) }
    }

    static var recentSearches: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(8)), forKey: recentSearchesKey) }
    }
}
