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
        case .queued: return "Queued"
        case .paused(let value): return "Paused · \(Self.percent(value))%"
        case .completed: return "Downloaded"
        case .failed: return "Download failed"
        case .idle: return nil
        }
    }

    /// The download fragment of an episode's spoken description.
    package var spokenText: String? {
        switch self {
        case .progress(let value): return "downloading \(Self.percent(value)) percent"
        case .queued: return "download queued"
        case .paused(let value): return "download paused at \(Self.percent(value)) percent"
        case .completed: return "downloaded"
        case .failed: return "download failed"
        case .idle: return nil
        }
    }

    private static func percent(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }
}
