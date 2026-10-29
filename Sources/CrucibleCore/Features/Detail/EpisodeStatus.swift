import Foundation

/// Everything an episode row shows about the state of one episode: the eyebrow, the meta line, the
/// thumbnail progress, the dimming of watched rows and the spoken description. Download state is
/// injected as a `DownloadBadge` so only iOS ever supplies one.
package struct EpisodeStatus: Equatable, Sendable {
    /// The eyebrow's state, in precedence order: watched, continue, downloading, up next, plain.
    package enum Marker: Equatable, Sendable {
        case watched
        case inProgress
        case downloading
        case upNext
        case plain

        /// Whether the eyebrow is drawn in the accent colour rather than the tertiary label colour.
        package var isEmphasised: Bool {
            self == .inProgress || self == .upNext
        }
    }

    package let episodeNumber: Int?
    package let title: String
    package let isWatched: Bool
    package let isInProgress: Bool
    package let progress: Double?
    package let marker: Marker
    package let eyebrow: String
    package let metaParts: [String]
    package let spokenText: String
    package let download: DownloadBadge
    package let playTitle: String
    package let canPlayFromBeginning: Bool
    package let watchedToggleTitle: String

    package init(episode: PlexMetadata, isUpNext: Bool, download: DownloadBadge = .idle) {
        let duration = episode.durationSecs
        let position = episode.positionSecs
        let isWatched = episode.isWatched
        let progress: Double? = !isWatched && position > 0 && duration > 0 ? position / duration : nil
        let inProgress = !isWatched && (progress ?? 0) > 0

        let number = episode.index.map { "E\($0)" } ?? "EPISODE"
        let marker: Marker
        let eyebrow: String
        if isWatched {
            marker = .watched
            eyebrow = "\(number) · WATCHED"
        } else if inProgress {
            marker = .inProgress
            eyebrow = "\(number) · CONTINUE"
        } else if download.isDownloading {
            marker = .downloading
            eyebrow = "\(number) · DOWNLOADING"
        } else if isUpNext {
            marker = .upNext
            eyebrow = "\(number) · UP NEXT"
        } else {
            marker = .plain
            eyebrow = number
        }

        var meta: [String] = []
        if let runtime = DetailFormat.runtime(duration) { meta.append(runtime) }
        if inProgress, let left = DetailFormat.remaining(position: position, duration: duration) {
            meta.append(left)
        }
        if let downloadText = download.metaText { meta.append(downloadText) }

        self.episodeNumber = episode.index
        self.title = episode.title
        self.isWatched = isWatched
        self.isInProgress = inProgress
        self.progress = progress
        self.marker = marker
        self.eyebrow = eyebrow
        self.metaParts = meta
        self.spokenText = Self.spokenDescription(episode: episode, inProgress: inProgress, download: download)
        self.download = download
        self.playTitle = inProgress ? "Resume" : "Play"
        self.canPlayFromBeginning = inProgress
        self.watchedToggleTitle = WatchedService.title(isWatched: isWatched)
    }

    package var metaText: String {
        metaParts.joined(separator: " · ")
    }

    /// Watched rows are dimmed so the unwatched ones stand out.
    package var contentAlpha: Double {
        isWatched ? 0.55 : 1
    }

    private static func spokenDescription(episode: PlexMetadata, inProgress: Bool, download: DownloadBadge) -> String {
        var parts: [String] = []
        if let number = episode.index { parts.append("Episode \(number)") }
        parts.append(episode.title)
        if episode.isWatched {
            parts.append("watched")
        } else if inProgress, let left = DetailFormat.spokenDuration(episode.durationSecs - episode.positionSecs) {
            parts.append("\(left) left")
        } else if let duration = DetailFormat.spokenDuration(episode.durationSecs) {
            parts.append(duration)
        }
        if let downloadText = download.spokenText { parts.append(downloadText) }
        return parts.joined(separator: ", ")
    }
}
