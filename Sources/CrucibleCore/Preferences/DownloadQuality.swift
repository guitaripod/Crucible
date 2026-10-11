import Foundation

package enum DownloadQuality: Int, Codable, CaseIterable, Sendable {
    case original = 0
    case high = 20000
    case medium = 8000
    case low = 3000
    case saver = 720

    package var title: String {
        switch self {
        case .original: return "Original"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .saver: return "Data Saver"
        }
    }

    package var detail: String {
        switch self {
        case .original: return "Source file · highest fidelity"
        case .high: return "1080p · 20 Mbps"
        case .medium: return "720p · 8 Mbps"
        case .low: return "480p · 3 Mbps"
        case .saver: return "360p · 0.7 Mbps"
        }
    }

    package var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .high: return "1080p"
        case .medium: return "720p"
        case .low: return "480p"
        case .saver: return "360p"
        }
    }

    /// Maximum video bitrate in kbps passed to the universal transcoder. `nil` for original (direct copy when possible).
    package var maxVideoBitrate: Int? {
        self == .original ? nil : rawValue
    }

    /// Estimated bytes for a transcoded download of the given duration, used to drive a smooth
    /// progress bar when the server streams a chunked transcode without a Content-Length.
    package func estimatedBytes(durationMs: Int) -> Int64 {
        guard let kbps = maxVideoBitrate else { return 0 }
        let seconds = Double(durationMs) / 1000.0
        let videoBytes = Double(kbps) * 1000.0 / 8.0 * seconds
        let audioBytes = 192_000.0 / 8.0 * seconds
        return Int64(videoBytes + audioBytes)
    }
}
