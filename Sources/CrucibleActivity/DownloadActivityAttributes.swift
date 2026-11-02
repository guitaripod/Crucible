#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Shared between the app (which starts/updates the Live Activity) and the widget extension
/// (which renders it on the Lock Screen and in the Dynamic Island).
public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public enum Status: String, Codable, Hashable {
            case downloading, paused, waitingForWiFi, queued, needsApp
        }

        public var showTitle: String
        public var episodeCode: String?
        public var episodeTitle: String?
        public var qualityLabel: String

        public var itemFraction: Double
        public var downloadedBytes: Int64
        public var totalBytes: Int64

        public var completedCount: Int
        public var totalCount: Int
        public var batchFraction: Double

        public var status: Status
        public var etaSeconds: Double?

        public init(
            showTitle: String,
            episodeCode: String?,
            episodeTitle: String?,
            qualityLabel: String,
            itemFraction: Double,
            downloadedBytes: Int64,
            totalBytes: Int64,
            completedCount: Int,
            totalCount: Int,
            batchFraction: Double,
            status: Status,
            etaSeconds: Double?
        ) {
            self.showTitle = showTitle
            self.episodeCode = episodeCode
            self.episodeTitle = episodeTitle
            self.qualityLabel = qualityLabel
            self.itemFraction = itemFraction
            self.downloadedBytes = downloadedBytes
            self.totalBytes = totalBytes
            self.completedCount = completedCount
            self.totalCount = totalCount
            self.batchFraction = batchFraction
            self.status = status
            self.etaSeconds = etaSeconds
        }

        public var itemPercentText: String { String(localized: "\(Int((itemFraction * 100).rounded()))%") }
        public var isPaused: Bool { status == .paused || status == .waitingForWiFi || status == .needsApp }
        public var clampedItemFraction: Double { min(1, max(0, itemFraction)) }
        public var clampedBatchFraction: Double { min(1, max(0, batchFraction)) }

        /// "S2E5 · Breakage" for episodes, or the quality label alone for movies.
        public var subtitleText: String {
            var parts = [String]()
            if let episodeCode { parts.append(episodeCode) }
            if let episodeTitle { parts.append(episodeTitle) }
            return parts.isEmpty ? qualityLabel : parts.joined(separator: " · ")
        }

        /// "Episode 3 of 13" (or "Item 3 of 13" for non-episode batches) — only when more than one
        /// item is in the session. `episodeCode` is nil exactly when the current item isn't an episode.
        public var batchText: String? {
            guard totalCount > 1 else { return nil }
            let position = min(completedCount + 1, totalCount)
            return episodeCode != nil ? String(localized: "Episode \(position) of \(totalCount)") : String(localized: "Item \(position) of \(totalCount)")
        }

        /// "142 MB of 1.1 GB", or just "142 MB" when the total is unknown.
        public var bytesText: String {
            let done = Self.byteString(downloadedBytes)
            guard totalBytes > 0 else { return done }
            return String(localized: "\(done) of \(Self.byteString(totalBytes))")
        }

        /// "~2 min left", or nil when no estimate is available.
        public var etaText: String? {
            guard let etaSeconds, etaSeconds.isFinite, etaSeconds > 0 else { return nil }
            let s = Int(etaSeconds.rounded())
            if s < 60 { return String(localized: "~\(max(s, 1))s left") }
            let m = (s + 30) / 60
            if m < 60 { return String(localized: "~\(m) min left") }
            return String(localized: "~\(m / 60)h \(m % 60)m left")
        }

        public var statusText: String {
            switch status {
            case .waitingForWiFi: return String(localized: "Waiting for Wi-Fi")
            case .paused: return String(localized: "Paused")
            case .queued: return String(localized: "Queued")
            case .downloading: return String(localized: "Downloading")
            case .needsApp: return String(localized: "Tap to resume")
            }
        }

        /// Self-contained byte formatter — the shared module cannot depend on the app's Formatters.
        private static func byteString(_ b: Int64) -> String {
            let gb = Double(b) / 1_073_741_824
            if gb >= 1 {
                let gigabytes = String(format: "%.1f", locale: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"), gb)
                return String(localized: "\(gigabytes) GB")
            }
            let megabytes = String(format: "%.0f", Double(b) / 1_048_576)
            return String(localized: "\(megabytes) MB")
        }
    }

    public init() {}
}
#endif
