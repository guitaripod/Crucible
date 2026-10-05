@preconcurrency import UIKit

/// Completed episodes of one show, collapsed into a single "Ready to Watch" row.
struct DownloadedShowGroup {
    let key: String
    let items: [DownloadItem]

    var title: String { items.first?.showTitle ?? "Show" }
    var posterKey: String { items.first?.ratingKey ?? key }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
    var unwatchedCount: Int { items.filter { !$0.isWatched }.count }
    var ratingKeys: [String] { items.map(\.ratingKey) }

    var seasonLabel: String {
        let seasons = Set(items.compactMap(\.seasonNumber)).sorted()
        switch seasons.count {
        case 0: return ""
        case 1: return "S\(seasons[0])"
        default: return "\(seasons.count) seasons"
        }
    }

    static func key(for item: DownloadItem) -> String {
        item.grandparentRatingKey ?? item.showTitle ?? item.ratingKey
    }

    static func groups(from items: [DownloadItem]) -> [DownloadedShowGroup] {
        let episodes = items.filter { $0.state == .completed && $0.mediaType == "episode" }
        let grouped = Dictionary(grouping: episodes, by: key(for:))
        return grouped.map { key, members in
            let sorted = members.sorted {
                ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
            }
            return DownloadedShowGroup(key: key, items: sorted)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// Builds the content configurations for every kind of Downloads row so the list and the per-show
/// screen render identically.
@MainActor
enum DownloadRowFactory {
    static func active(_ item: DownloadItem, rate: Double?) -> DownloadRowConfiguration {
        var config = DownloadRowConfiguration(posterKey: item.ratingKey, title: item.displayTitle)
        config.subtitle = item.episodeSubtitle
        config.placeholderIcon = item.mediaType == "episode" ? "tv" : "film"
        let ratingKey = item.ratingKey
        switch item.state {
        case .downloading:
            config.progress = item.progress
            config.status = downloadingStatus(item, rate: rate)
            config.ring = .progress(item.progress)
            config.onRingTap = { DownloadManager.shared.pause(ratingKey) }
        case .queued:
            config.progress = item.progress > 0 ? item.progress : nil
            config.status = "Queued · \(item.quality.shortLabel)"
            config.statusTone = .secondary
            config.ring = .queued
            config.ringHint = "Queued. Double tap to pause"
            config.onRingTap = { DownloadManager.shared.pause(ratingKey) }
            config.contentAlpha = 0.8
        case .waitingForWiFi:
            config.status = "Waiting for Wi-Fi"
            config.statusTone = .secondary
            config.statusSymbol = "wifi"
            config.ring = .queued
            config.ringHint = "Waiting for Wi-Fi. Double tap to pause"
            config.onRingTap = { DownloadManager.shared.pause(ratingKey) }
            config.contentAlpha = 0.8
        case .paused:
            config.progress = item.progress
            config.status = "Paused · \(item.percentText)"
            config.statusTone = .secondary
            config.ring = .paused(item.progress)
            config.onRingTap = { DownloadManager.shared.resume(ratingKey) }
        case .failed:
            config.status = item.errorMessage ?? "Download failed"
            config.statusTone = .error
            config.ring = .failed
            config.onRingTap = { DownloadManager.shared.retry(ratingKey) }
        case .completed:
            break
        }
        return config
    }

    /// "64% · 3.2 MB/s · 4 min left", dropping whatever cannot be estimated yet.
    private static func downloadingStatus(_ item: DownloadItem, rate: Double?) -> String {
        var parts = [item.percentText]
        guard let rate else { return parts.joined() }
        parts.append(DownloadFormat.rate(rate))
        let total = item.totalBytes > 0 ? item.totalBytes : item.estimatedBytes
        let remaining = Double(total - item.downloadedBytes)
        if total > 0, remaining > 0 { parts.append(DownloadFormat.remaining(remaining / rate)) }
        return parts.joined(separator: " · ")
    }

    static func movie(_ item: DownloadItem) -> DownloadRowConfiguration {
        var config = DownloadRowConfiguration(posterKey: item.ratingKey, title: item.title)
        config.placeholderIcon = "film"
        var subtitle = ["Movie"]
        let runtime = DownloadFormat.runtime(item.durationSecs)
        if !runtime.isEmpty { subtitle.append(runtime) }
        config.subtitle = subtitle.joined(separator: " · ")
        config.status = completedMeta(item, includeWatchState: true)
        config.statusTone = .tertiary
        config.contentAlpha = item.isWatched ? 0.55 : 1
        return config
    }

    static func episode(_ item: DownloadItem) -> DownloadRowConfiguration {
        var config = DownloadRowConfiguration(posterKey: item.ratingKey, title: item.title)
        config.placeholderIcon = "tv"
        config.subtitle = Formatters.episodeCode(item.seasonNumber, item.episodeNumber)
        config.status = completedMeta(item, includeWatchState: true)
        config.statusTone = .tertiary
        config.contentAlpha = item.isWatched ? 0.55 : 1
        return config
    }

    static func show(_ group: DownloadedShowGroup) -> DownloadRowConfiguration {
        var config = DownloadRowConfiguration(posterKey: group.posterKey, title: group.title)
        config.placeholderIcon = "tv"
        config.isStacked = true
        let count = group.items.count
        var subtitle = ["\(count) \(count == 1 ? "episode" : "episodes")"]
        if !group.seasonLabel.isEmpty { subtitle.append(group.seasonLabel) }
        config.subtitle = subtitle.joined(separator: " · ")
        var meta = [String]()
        if group.totalBytes > 0 { meta.append(Formatters.fileSize(group.totalBytes)) }
        meta.append(group.unwatchedCount == 0 ? "Watched" : "\(group.unwatchedCount) unwatched")
        config.status = meta.joined(separator: " · ")
        config.statusTone = .tertiary
        return config
    }

    private static func completedMeta(_ item: DownloadItem, includeWatchState: Bool) -> String {
        var parts = [String]()
        if item.totalBytes > 0 { parts.append(Formatters.fileSize(item.totalBytes)) }
        if includeWatchState {
            if item.isWatched {
                parts.append("Watched")
            } else if item.viewOffsetMs > 0, item.durationMs > item.viewOffsetMs {
                let left = DownloadFormat.runtime(Double(item.durationMs - item.viewOffsetMs) / 1000)
                if !left.isEmpty { parts.append("\(left) left") }
            }
        }
        return parts.joined(separator: " · ")
    }
}
