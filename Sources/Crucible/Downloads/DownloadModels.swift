import Foundation

enum DownloadQuality: Int, Codable, CaseIterable, Sendable {
    case original = 0
    case high = 20000
    case medium = 8000
    case low = 3000
    case saver = 720

    var title: String {
        switch self {
        case .original: return "Original"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .saver: return "Data Saver"
        }
    }

    var detail: String {
        switch self {
        case .original: return "Source file · highest fidelity"
        case .high: return "1080p · 20 Mbps"
        case .medium: return "720p · 8 Mbps"
        case .low: return "480p · 3 Mbps"
        case .saver: return "360p · 0.7 Mbps"
        }
    }

    var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .high: return "1080p"
        case .medium: return "720p"
        case .low: return "480p"
        case .saver: return "360p"
        }
    }

    /// Maximum video bitrate in kbps passed to the universal transcoder. `nil` for original (direct copy when possible).
    var maxVideoBitrate: Int? {
        self == .original ? nil : rawValue
    }

    /// Estimated bytes for a transcoded download of the given duration, used to drive a smooth
    /// progress bar when the server streams a chunked transcode without a Content-Length.
    func estimatedBytes(durationMs: Int) -> Int64 {
        guard let kbps = maxVideoBitrate else { return 0 }
        let seconds = Double(durationMs) / 1000.0
        let videoBytes = Double(kbps) * 1000.0 / 8.0 * seconds
        let audioBytes = 192_000.0 / 8.0 * seconds
        return Int64(videoBytes + audioBytes)
    }
}

enum DownloadState: String, Codable, Sendable {
    case queued
    case waitingForWiFi
    case downloading
    case paused
    case completed
    case failed

    var isActive: Bool {
        self == .queued || self == .waitingForWiFi || self == .downloading
    }

    var isTerminal: Bool {
        self == .completed
    }
}

struct StoredMarker: Codable, Sendable {
    let type: String
    let startMs: Int
    let endMs: Int

    var asPlexMarker: PlexMarker {
        PlexMarker(type: type, startTimeOffset: startMs, endTimeOffset: endMs, final: nil)
    }
}

struct DownloadItem: Codable, Sendable {
    let ratingKey: String
    let mediaType: String
    let title: String
    let showTitle: String?
    let grandparentRatingKey: String?
    let parentRatingKey: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let year: Int?
    var durationMs: Int
    var summary: String?
    let plexThumbPath: String?

    let quality: DownloadQuality
    var isTranscoded: Bool
    var fileExtension: String
    /// Path of the downloaded HLS `.movpkg` bundle, relative to the app home directory
    /// (the system manages the absolute location, which is stable within an install).
    var hlsRelativePath: String?

    var state: DownloadState
    var progress: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    var estimatedBytes: Int64
    var errorMessage: String?

    let createdAt: Date
    var completedAt: Date?
    var viewOffsetMs: Int
    var markers: [StoredMarker]

    var id: String { ratingKey }

    var mediaFileName: String { "\(ratingKey).\(fileExtension)" }
    var posterFileName: String { "\(ratingKey).jpg" }
    var resumeDataFileName: String { "\(ratingKey).resume" }

    var displayTitle: String {
        if mediaType == "episode", let show = showTitle { return show }
        return title
    }

    var episodeSubtitle: String? {
        guard mediaType == "episode" else { return year.map(String.init) }
        var parts = [String]()
        if let code = Formatters.episodeCode(seasonNumber, episodeNumber) { parts.append(code) }
        parts.append(title)
        return parts.joined(separator: " · ")
    }

    var durationSecs: Double { Double(durationMs) / 1000.0 }
    var resumeSecs: Double { Double(viewOffsetMs) / 1000.0 }

    var watchProgress: Double {
        guard durationMs > 0 else { return 0 }
        return min(1, Double(viewOffsetMs) / Double(durationMs))
    }

    var isWatched: Bool {
        durationMs > 0 && viewOffsetMs > 0 && watchProgress >= 0.92
    }

    /// Best-effort byte size known for this download: the real total when the server reports one,
    /// otherwise the transcode estimate, otherwise what has been written so far.
    var knownBytes: Int64 {
        if totalBytes > 0 { return totalBytes }
        if estimatedBytes > 0 { return estimatedBytes }
        return downloadedBytes
    }
}

extension DownloadItem {
    /// Minimal metadata reconstructed from the download, so a detail screen renders (hero + Play)
    /// for a downloaded item even with no network.
    var asPlexMetadata: PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey, key: nil, type: mediaType, title: title,
            grandparentTitle: showTitle, grandparentRatingKey: grandparentRatingKey,
            grandparentThumb: mediaType == "episode" ? plexThumbPath : nil, grandparentArt: nil,
            parentTitle: nil, parentRatingKey: parentRatingKey, parentThumb: nil,
            parentIndex: seasonNumber, index: episodeNumber, year: year, summary: summary,
            tagline: nil, contentRating: nil, studio: nil, rating: nil, audienceRating: nil,
            duration: durationMs, viewOffset: viewOffsetMs, viewCount: isWatched ? 1 : 0, lastViewedAt: nil,
            addedAt: nil, originallyAvailableAt: nil,
            thumb: plexThumbPath, art: nil,
            leafCount: nil, viewedLeafCount: nil, childCount: nil,
            Genre: nil, Role: nil, Director: nil, Writer: nil,
            Media: nil, Marker: markers.map(\.asPlexMarker), Related: nil
        )
    }
}

enum DownloadEvent: Sendable {
    case changed
    case progress(ratingKey: String, fractionCompleted: Double, downloadedBytes: Int64, totalBytes: Int64)
    case finished(ratingKey: String)
    case failed(ratingKey: String, message: String)
}

struct OfflineAsset: Sendable {
    let fileURL: URL
    let markers: [PlexMarker]
    let durationSecs: Double
    let resumeSecs: Double
}
