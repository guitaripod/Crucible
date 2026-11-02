import Foundation

/// A platform-neutral download state for one item. Downloads exist on iPhone only, so iOS maps its
/// download manager onto this and screens that have no downloads pass `.idle` (the default).
package enum DownloadBadge: Equatable, Sendable {
    case idle
    case queued
    case progress(Double)
    case paused(Double)
    case completed
    case failed

    /// True while bytes are moving or about to move.
    package var isDownloading: Bool {
        switch self {
        case .progress, .queued: return true
        default: return false
        }
    }

    /// The download fragment of an episode's meta line ("42%", "Paused · 42%", "Downloaded").
    package var metaText: String? {
        switch self {
        case .progress(let value): return "\(Self.percent(value))%"
        case .queued: return String(localized: "Queued", comment: "Download is waiting to start")
        case .paused(let value): return String(localized: "Paused · \(Self.percent(value))%")
        case .completed: return String(localized: "Downloaded", comment: "Download has finished")
        case .failed: return String(localized: "Download failed")
        case .idle: return nil
        }
    }

    /// The download fragment of an episode's spoken description.
    package var spokenText: String? {
        switch self {
        case .progress(let value): return String(localized: "downloading \(Self.percent(value)) percent")
        case .queued: return String(localized: "download queued")
        case .paused(let value): return String(localized: "download paused at \(Self.percent(value)) percent")
        case .completed: return String(localized: "downloaded")
        case .failed: return String(localized: "download failed")
        case .idle: return nil
        }
    }

    private static func percent(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }
}
