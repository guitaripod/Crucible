import CrucibleCore
import Foundation

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
    var resumeSecs: Double { isWatched ? 0 : Double(viewOffsetMs) / 1000.0 }

    var watchProgress: Double {
        WatchedRule.progress(positionMs: viewOffsetMs, durationMs: durationMs)
    }

    var isWatched: Bool {
        WatchedRule.isWatched(positionMs: viewOffsetMs, durationMs: durationMs)
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
            viewedAt: nil, accountID: nil, deviceID: nil,
            addedAt: nil, originallyAvailableAt: nil,
            thumb: plexThumbPath, art: nil,
            leafCount: nil, viewedLeafCount: nil, childCount: nil,
            librarySectionID: nil, librarySectionTitle: nil,
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
