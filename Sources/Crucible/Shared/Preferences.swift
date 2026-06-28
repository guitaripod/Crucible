import Foundation

enum Preferences {
    private static let qualityKey = "streamingQuality"
    private static let downloadQualityKey = "downloadQuality"
    private static let downloadCellularKey = "downloadOverCellular"
    private static let downloadConcurrencyKey = "downloadConcurrency"
    private static let deleteWatchedKey = "deleteWatchedDownloads"

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
}
