import Foundation

enum Preferences {
    private static let qualityKey = "streamingQuality"

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
}
