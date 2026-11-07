import Foundation

/// Turns the Home buckets into the Top Shelf snapshot: up to ten full-screen carousel cards, Continue Watching first, then
/// Up Next, then titles just added to the server. Each card carries the 16:9 artwork in the two sizes the Apple TV asks
/// for, the facts the details carousel lays out (genre, runtime, release date, media badges, cast) and a preview video:
/// the scene where the viewer stopped for something under way, the title's trailer for the rest.
package enum TopShelfBuilder {
    /// Apple's guidance for the carousel is five to ten cards.
    package static let maxItems = 10
    package static let imageWidth = 1920
    package static let imageHeight = 1080
    package static let image2xWidth = 3840
    package static let image2xHeight = 2160
    package static let summaryLimit = 280
    /// How far before the saved place a scene preview starts, so the viewer sees the moment they left.
    package static let sceneLeadIn: Double = 10
    /// The carousel stacks its named attributes in a narrow column of about four lines beside the summary, so each
    /// attribute is kept to what fits on one or two of them.
    static let maxAttributes = 4
    static let maxCast = 2

    package struct Source: Sendable {
        package let serverURL: URL
        package let token: String
        package let machineIdentifier: String
        package let clientIdentifier: String
        package let platform: String
        /// The ceiling a transcoded preview is held to, in kbps; nil streams the original quality.
        package let maxVideoBitrate: Int?

        package init(
            serverURL: URL,
            token: String,
            machineIdentifier: String,
            clientIdentifier: String = "crucible",
            platform: String = "tvOS",
            maxVideoBitrate: Int? = nil
        ) {
            self.serverURL = serverURL
            self.token = token
            self.machineIdentifier = machineIdentifier
            self.clientIdentifier = clientIdentifier
            self.platform = platform
            self.maxVideoBitrate = maxVideoBitrate
        }
    }

    /// The row of Home a card comes from, in carousel order.
    package enum Kind: Sendable, CaseIterable {
        case continueWatching
        case upNext
        case recentlyAdded

        package var title: String {
            switch self {
            case .continueWatching: String(localized: "Continue Watching")
            case .upNext: String(localized: "Up Next")
            case .recentlyAdded: String(localized: "Recently Added")
            }
        }

        /// Cards each row gets before the slots it leaves empty go to the others.
        var share: Int {
            switch self {
            case .continueWatching, .upNext: 4
            case .recentlyAdded: 2
            }
        }
    }

    package struct Pick: Sendable {
        package let item: PlexMetadata
        package let kind: Kind

        package init(item: PlexMetadata, kind: Kind) {
            self.item = item
            self.kind = kind
        }
    }

    /// What the server adds to a picked title beyond its Home hub entry: its full metadata (media streams, cast,
    /// trailers), its show's for an episode, and the episode after a Continue Watching episode.
    package struct Details: Sendable {
        package var item: PlexMetadata?
        package var show: PlexMetadata?
        package var next: PlexMetadata?

        package init(item: PlexMetadata? = nil, show: PlexMetadata? = nil, next: PlexMetadata? = nil) {
            self.item = item
            self.show = show
            self.next = next
        }
    }

    package struct Preview: Equatable, Sendable {
        package let url: URL
        /// The transcoder session the URL starts; nil for a file the server sends as it is.
        package let session: String?
    }

    /// The titles the carousel shows. Libraries left out of Home stay out, nothing appears twice, Up Next never repeats
    /// Continue Watching, and Recently Added offers only movies and shows nobody has started that are not already there.
    package static func picks(buckets: HomeBuckets, excludedLibraries: Set<Int>) -> [Pick] {
        let visible = buckets.visible(excluding: excludedLibraries)
        let continuing = visible.continueWatching
        var shown = Set(continuing.map(\.id))
        let upNext = visible.onDeck.filter { !shown.contains($0.id) }
        shown.formUnion(upNext.map(\.id))
        shown.formUnion((continuing + upNext).compactMap(\.grandparentRatingKey))
        let recent = visible.recent.filter { isUnstarted($0) && !shown.contains($0.id) }
        let rows: [(kind: Kind, items: [PlexMetadata])] = [(.continueWatching, continuing), (.upNext, upNext), (.recentlyAdded, recent)]
        let counts = allocate(rows.map(\.items.count), shares: rows.map(\.kind.share), total: maxItems)
        return zip(rows, counts).flatMap { row, count in row.items.prefix(count).map { Pick(item: $0, kind: row.kind) } }
    }

    /// A movie with no progress and no view, or a show with episodes and none of them watched.
    static func isUnstarted(_ item: PlexMetadata) -> Bool {
        switch item.mediaType {
        case "movie": return HomeMediaRules.isUnwatched(item)
        case "show": return (item.leafCount ?? 0) > 0 && (item.viewedLeafCount ?? 0) == 0
        default: return false
        }
    }

    /// Each row takes up to its share, then the slots left over go to the rows that have more, in carousel order.
    static func allocate(_ counts: [Int], shares: [Int], total: Int) -> [Int] {
        var taken = zip(counts, shares).map { min($0, $1) }
        var left = max(0, total - taken.reduce(0, +))
        for index in taken.indices where left > 0 {
            let extra = min(counts[index] - taken[index], left)
            taken[index] += extra
            left -= extra
        }
        return taken
    }

    /// The snapshot for the picks, enriched by whatever details arrived.
    package static func snapshot(picks: [Pick], details: [String: Details] = [:], source: Source, now: Date) -> TopShelfSnapshot {
        let sections = Kind.allCases.compactMap { kind -> TopShelfSection? in
            let items = picks.filter { $0.kind == kind }.map { item(from: $0, details: details[$0.item.id] ?? Details(), source: source, now: now) }
            return items.isEmpty ? nil : TopShelfSection(title: kind.title, items: items)
        }
        return TopShelfSnapshot(machineIdentifier: source.machineIdentifier, savedAt: Int(now.timeIntervalSince1970), sections: sections)
    }

    package static func snapshot(buckets: HomeBuckets, source: Source, excludedLibraries: Set<Int>, now: Date) -> TopShelfSnapshot {
        snapshot(picks: picks(buckets: buckets, excludedLibraries: excludedLibraries), source: source, now: now)
    }

    /// Full-screen artwork: the show's backdrop for an episode (an episode still is often too small to fill a 4K screen),
    /// a movie's or show's own backdrop, the still or poster as a last resort.
    package static func imagePath(for item: PlexMetadata) -> String? {
        item.mediaType == "episode"
            ? (item.grandparentArt ?? item.thumb ?? item.art)
            : (item.art ?? item.thumb)
    }

    /// The server's photo transcoder at the Top Shelf's 16:9 size, authorised by a token query item.
    package static func imageURL(path: String, width: Int = imageWidth, height: Int = imageHeight, source: Source) -> URL? {
        url(path: "/photo/:/transcode", query: [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: source.token),
        ], source: source)
    }

    /// The line above the title: the row it comes from, how much is left of something under way, and for an episode
    /// that is more than just the next one, why ("New Episode", "New Season").
    package static func contextTitle(for pick: Pick, now: Date) -> String {
        let item = pick.item
        switch pick.kind {
        case .continueWatching:
            return HomeFormat.joined([pick.kind.title, HomeFormat.remaining(item, position: item.continueSecs)]) ?? pick.kind.title
        case .upNext:
            let label = HomeFormat.episodeNews(item, now: now)?.eyebrow ?? pick.kind.title
            return HomeFormat.joined([label, HomeFormat.remaining(item)]) ?? label
        case .recentlyAdded:
            return pick.kind.title
        }
    }

    /// The item's own synopsis, trimmed to what a carousel card can show without a scroll.
    package static func summary(for item: PlexMetadata) -> String? {
        guard let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        guard summary.count > summaryLimit else { return summary }
        let cut = summary.prefix(summaryLimit)
        guard let space = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return String(cut[..<space]) + "…"
    }

    /// The first genre of the title, or of its show for an episode.
    package static func genre(for item: PlexMetadata, details: Details) -> String? {
        let source = item.mediaType == "episode" ? details.show : (details.item ?? item)
        return source?.Genre?.first.map(\.tag).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The episode and the one after it, the leading cast (the show's for an episode) and a movie's director.
    package static func attributes(for item: PlexMetadata, details: Details) -> [TopShelfAttribute] {
        var attributes = [TopShelfAttribute]()
        if item.mediaType == "episode" {
            attributes.append(TopShelfAttribute(name: String(localized: "Episode"), values: [episodeLine(item)]))
            if let next = details.next {
                let sameSeason = next.parentIndex == nil || next.parentIndex == item.parentIndex
                let line = HomeFormat.episodeLine(season: sameSeason ? nil : next.parentIndex, episode: next.index, tail: next.title)
                attributes.append(TopShelfAttribute(name: String(localized: "Next Episode"), values: [line]))
            }
        }
        let castSource = item.mediaType == "episode" ? (details.show ?? details.item) : details.item
        let cast = (castSource?.Role ?? []).compactMap(\.tag).filter { !$0.isEmpty }.prefix(maxCast)
        if !cast.isEmpty {
            attributes.append(TopShelfAttribute(name: String(localized: "Starring", comment: "Top Shelf heading over the leading actors of a title"), values: Array(cast)))
        }
        if item.mediaType == "movie" {
            let directors = (details.item?.Director ?? []).map(\.tag).filter { !$0.isEmpty }.prefix(2)
            if !directors.isEmpty {
                let name = directors.count == 1 ? String(localized: "Director") : String(localized: "Directors")
                attributes.append(TopShelfAttribute(name: name, values: Array(directors)))
            }
        }
        return Array(attributes.prefix(maxAttributes))
    }

    /// The capability badges of the file the card plays, read from its streams: one resolution, one dynamic range,
    /// Atmos on the main audio track, and the accessibility tracks it carries. Empty without the full metadata.
    package static func mediaOptions(for item: PlexMetadata?) -> [TopShelfMediaOption] {
        guard let item, let media = item.Media?.first else { return [] }
        var options = [TopShelfMediaOption]()
        let width = media.width ?? 0
        let height = media.height ?? 0
        let resolution = media.videoResolution?.lowercased()
        if resolution == "4k" || width >= 3840 || height >= 2160 {
            options.append(.uhd)
        } else if width >= 1280 || height >= 720 || ["720", "1080"].contains(resolution) {
            options.append(.hd)
        }
        switch DetailFormat.dynamicRange(item) {
        case .some(DetailFormat.dolbyVisionBadge): options.append(.dolbyVision)
        case .some: options.append(.hdr)
        case nil: break
        }
        if DetailFormat.primaryAudioStream(item).map(DetailFormat.isAtmos) == true { options.append(.atmos) }
        let subtitles = item.subtitleStreams
        if subtitles.contains(where: isClosedCaption) { options.append(.closedCaptions) }
        if subtitles.contains(where: { describes($0, any: ["sdh", "hearing impaired"]) }) { options.append(.sdh) }
        if item.audioStreams.contains(where: { describes($0, any: ["descri", "deskri"]) }) { options.append(.audioDescription) }
        return options
    }

    /// What plays once focus rests on the card: the scene where the viewer stopped for something under way, the
    /// title's trailer (the show's for an episode) for the rest, nothing when the server has no trailer.
    package static func preview(for pick: Pick, details: Details, source: Source) -> Preview? {
        let item = pick.item
        if ["movie", "episode"].contains(item.mediaType), item.continueSecs > 0 {
            return scene(of: item, at: item.continueSecs, source: source)
        }
        let owner = item.mediaType == "episode" ? details.show : details.item
        return trailer(in: owner).flatMap { trailerPreview($0, source: source) }
    }

    /// The first trailer among a title's extras that has something to play.
    package static func trailer(in item: PlexMetadata?) -> PlexMetadata? {
        guard let item else { return nil }
        return DetailExtras.items(in: item).first { $0.subtype == "trailer" }
    }

    /// The episode after `episode` among its season's episodes.
    package static func episode(after episode: PlexMetadata, in episodes: [PlexMetadata]) -> PlexMetadata? {
        guard let index = episode.index else { return nil }
        return episodes
            .filter { $0.mediaType == "episode" && ($0.index ?? 0) > index }
            .min { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    /// The season after season `number`, skipping specials, which come before every season.
    package static func season(after number: Int, in seasons: [PlexMetadata]) -> PlexMetadata? {
        seasons
            .filter { $0.mediaType == "season" && ($0.index ?? 0) > number }
            .min { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    /// The HLS stream the scene preview plays: the title itself from a little before `position`, the picture and sound
    /// copied where the Apple TV can play them, so the server only repackages it.
    static func scene(of item: PlexMetadata, at position: Double, source: Source) -> Preview? {
        let session = "topshelf-\(item.id)"
        return transcodeURL(path: "/library/metadata/\(item.id)", offset: max(0, position - sceneLeadIn), session: session, source: source)
            .map { Preview(url: $0, session: session) }
    }

    /// A trailer the Apple TV plays as it is when the file allows, through the transcoder's HLS otherwise.
    static func trailerPreview(_ trailer: PlexMetadata, source: Source) -> Preview? {
        if let media = trailer.Media?.first, let part = media.Part?.first, part.key.hasPrefix("/"),
           StreamResolver.isDirectPlayable(container: media.container?.lowercased(), videoCodec: media.videoCodec, audioCodec: media.audioCodec),
           let url = directURL(partKey: part.key, source: source) {
            return Preview(url: url, session: nil)
        }
        let session = "topshelf-\(trailer.id)"
        return transcodeURL(path: "/library/metadata/\(trailer.id)", offset: nil, session: session, source: source)
            .map { Preview(url: $0, session: session) }
    }

    /// The universal transcoder's HLS playlist, authorised and identified entirely by query items: the system player
    /// that fetches it can send no headers.
    static func transcodeURL(path: String, offset: Double?, session: String, source: Source) -> URL? {
        var query = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "subtitles", value: "none"),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
        ]
        if let offset { query.append(URLQueryItem(name: "offset", value: "\(Int(StreamPosition.transcodeStart(offset)))")) }
        if let bitrate = source.maxVideoBitrate {
            query.append(URLQueryItem(name: "maxVideoBitrate", value: "\(bitrate)"))
            query.append(URLQueryItem(name: "videoQuality", value: "100"))
        }
        query += identity(source)
        return url(path: "/video/:/transcode/universal/start.m3u8", query: query, source: source)
    }

    static func directURL(partKey: String, source: Source) -> URL? {
        guard var components = URLComponents(string: base(source) + partKey) else { return nil }
        components.queryItems = (components.queryItems ?? []) + identity(source)
        return components.url
    }

    private static func identity(_ source: Source) -> [URLQueryItem] {
        [
            URLQueryItem(name: "X-Plex-Token", value: source.token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: source.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: source.platform),
            URLQueryItem(name: "X-Plex-Product", value: "Crucible"),
        ]
    }

    private static func url(path: String, query: [URLQueryItem], source: Source) -> URL? {
        guard var components = URLComponents(string: base(source) + path) else { return nil }
        components.queryItems = query
        return components.url
    }

    private static func base(_ source: Source) -> String {
        source.serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func episodeLine(_ episode: PlexMetadata) -> String {
        HomeFormat.episodeLine(season: episode.parentIndex, episode: episode.index, tail: episode.title)
    }

    /// Captions carried in the video (EIA-608/708) or a track the server labels CC.
    private static func isClosedCaption(_ stream: PlexStream) -> Bool {
        if let codec = stream.codec?.lowercased(), ["eia_608", "eia_708", "cc_dec"].contains(codec) { return true }
        let label = [stream.displayTitle, stream.title].compactMap { $0 }.joined(separator: " ")
        return label.range(of: #"\bCC\b"#, options: .regularExpression) != nil
    }

    private static func describes(_ stream: PlexStream, any words: [String]) -> Bool {
        let label = [stream.displayTitle, stream.title].compactMap { $0 }.joined(separator: " ").lowercased()
        return words.contains { label.contains($0) }
    }

    private static func item(from pick: Pick, details: Details, source: Source, now: Date) -> TopShelfItem {
        let metadata = pick.item
        let path = imagePath(for: metadata)
        let preview = preview(for: pick, details: details, source: source)
        let options = mediaOptions(for: details.item)
        let attributes = attributes(for: metadata, details: details)
        return TopShelfItem(
            ratingKey: metadata.id,
            type: metadata.mediaType,
            title: HomeFormat.title(for: metadata),
            subtitle: contextTitle(for: pick, now: now),
            summary: summary(for: metadata) ?? details.show.flatMap(summary(for:)),
            imageURL: path.flatMap { imageURL(path: $0, source: source) },
            image2xURL: path.flatMap { imageURL(path: $0, width: image2xWidth, height: image2xHeight, source: source) },
            progress: progress(of: metadata),
            genre: genre(for: metadata, details: details),
            duration: ["movie", "episode"].contains(metadata.mediaType) && metadata.durationSecs > 0 ? metadata.durationSecs : nil,
            releaseDate: metadata.originallyAvailableAt,
            mediaOptions: options.isEmpty ? nil : options,
            attributes: attributes.isEmpty ? nil : attributes,
            previewURL: preview?.url,
            previewSession: preview?.session
        )
    }

    private static func progress(of metadata: PlexMetadata) -> Double? {
        guard metadata.resumeSecs > 0, metadata.duration != nil else { return nil }
        return min(max(metadata.progressFraction, 0), 1)
    }
}
