import Foundation

/// Turns the Home buckets into the Top Shelf snapshot: "Continue Watching" and "Up Next" with the
/// 16:9 artwork URLs the Apple TV fetches itself, in the two sizes the system asks for.
package enum TopShelfBuilder {
    package static let maxItemsPerSection = 12
    package static let imageWidth = 1920
    package static let imageHeight = 1080
    package static let image2xWidth = 3840
    package static let image2xHeight = 2160
    package static let summaryLimit = 280

    package struct Source: Sendable {
        package let serverURL: URL
        package let token: String
        package let machineIdentifier: String

        package init(serverURL: URL, token: String, machineIdentifier: String) {
            self.serverURL = serverURL
            self.token = token
            self.machineIdentifier = machineIdentifier
        }
    }

    /// Libraries left out of Home stay off the Top Shelf, duplicates collapse, and Up Next never
    /// repeats what Continue Watching already shows.
    package static func snapshot(
        buckets: HomeBuckets,
        source: Source,
        excludedLibraries: Set<Int>,
        now: Date
    ) -> TopShelfSnapshot {
        let visible = buckets.visible(excluding: excludedLibraries)
        let continueIDs = Set(visible.continueWatching.map(\.id))
        let upNext = visible.onDeck.filter { !continueIDs.contains($0.id) }

        let continueSection = TopShelfSection(
            title: "Continue Watching",
            items: visible.continueWatching.prefix(maxItemsPerSection).map { item(from: $0, section: "Continue Watching", source: source) }
        )
        let upNextSection = TopShelfSection(
            title: "Up Next",
            items: upNext.prefix(maxItemsPerSection).map { item(from: $0, section: "Up Next", source: source) }
        )
        return TopShelfSnapshot(
            machineIdentifier: source.machineIdentifier,
            savedAt: Int(now.timeIntervalSince1970),
            sections: [continueSection, upNextSection].filter { !$0.items.isEmpty }
        )
    }

    /// Landscape artwork: an episode's still first, a movie's backdrop first.
    package static func imagePath(for item: PlexMetadata) -> String? {
        item.mediaType == "episode"
            ? (item.thumb ?? item.grandparentArt ?? item.art)
            : (item.art ?? item.thumb)
    }

    /// The server's photo transcoder at the Top Shelf's 16:9 size, authorised by a token query item.
    package static func imageURL(path: String, width: Int = imageWidth, height: Int = imageHeight, source: Source) -> URL? {
        let base = source.serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/photo/:/transcode") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: source.token),
        ]
        return components.url
    }

    /// What the card says above its summary: the show and episode for a series, why it is being
    /// shown for anything else.
    package static func contextTitle(for item: PlexMetadata, section: String) -> String? {
        guard item.mediaType == "episode" else { return section }
        return HomeFormat.joined([item.grandparentTitle, HomeFormat.episodeLine(season: item.parentIndex, episode: item.index, tail: nil)])
    }

    /// The item's own synopsis, trimmed to what a carousel card can show without a scroll.
    package static func summary(for item: PlexMetadata) -> String? {
        guard let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        guard summary.count > summaryLimit else { return summary }
        let cut = summary.prefix(summaryLimit)
        guard let space = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return String(cut[..<space]) + "…"
    }

    private static func item(from metadata: PlexMetadata, section: String, source: Source) -> TopShelfItem {
        let path = imagePath(for: metadata)
        return TopShelfItem(
            ratingKey: metadata.id,
            type: metadata.mediaType,
            title: metadata.title ?? HomeFormat.title(for: metadata),
            subtitle: contextTitle(for: metadata, section: section),
            summary: summary(for: metadata),
            imageURL: path.flatMap { imageURL(path: $0, source: source) },
            image2xURL: path.flatMap { imageURL(path: $0, width: image2xWidth, height: image2xHeight, source: source) },
            progress: progress(of: metadata)
        )
    }

    private static func progress(of metadata: PlexMetadata) -> Double? {
        guard metadata.positionSecs > 0, metadata.duration != nil else { return nil }
        return min(max(metadata.progressPercent, 0), 1)
    }
}
