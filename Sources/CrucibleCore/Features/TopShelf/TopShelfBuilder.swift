import Foundation

/// Turns the Home buckets into the Top Shelf snapshot: "Continue Watching" and "Up Next"
/// with 16:9 artwork URLs the Apple TV fetches itself.
package enum TopShelfBuilder {
    package static let maxItemsPerSection = 12
    package static let imageWidth = 1816
    package static let imageHeight = 1024

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
            items: visible.continueWatching.prefix(maxItemsPerSection).map { item(from: $0, subtitle: HomeFormat.continueSubtitle(for: $0), source: source) }
        )
        let upNextSection = TopShelfSection(
            title: "Up Next",
            items: upNext.prefix(maxItemsPerSection).map { item(from: $0, subtitle: HomeFormat.upNextSubtitle(for: $0), source: source) }
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
    package static func imageURL(path: String, source: Source) -> URL? {
        let base = source.serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/photo/:/transcode") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(imageWidth)"),
            URLQueryItem(name: "height", value: "\(imageHeight)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: source.token),
        ]
        return components.url
    }

    private static func item(from metadata: PlexMetadata, subtitle: String?, source: Source) -> TopShelfItem {
        TopShelfItem(
            ratingKey: metadata.id,
            type: metadata.mediaType,
            title: HomeFormat.title(for: metadata),
            subtitle: subtitle,
            imageURL: imagePath(for: metadata).flatMap { imageURL(path: $0, source: source) },
            progress: progress(of: metadata)
        )
    }

    private static func progress(of metadata: PlexMetadata) -> Double? {
        guard metadata.resumeSecs > 0, metadata.duration != nil else { return nil }
        return min(max(metadata.progressFraction, 0), 1)
    }
}
