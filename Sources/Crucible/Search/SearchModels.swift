@preconcurrency import UIKit

enum SearchScope: Int, CaseIterable {
    case all, movies, shows, episodes

    var title: String {
        switch self {
        case .all: return "All"
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .episodes: return "Episodes"
        }
    }

    func includes(_ mediaType: String) -> Bool {
        switch self {
        case .all: return true
        case .movies: return mediaType == "movie"
        case .shows: return mediaType == "show"
        case .episodes: return mediaType == "episode"
        }
    }
}

enum SearchSection: Int, Hashable {
    case recent, browse, recentlyAdded, topResult, movies, shows, episodes

    var title: String? {
        switch self {
        case .recent: return "Recent"
        case .browse: return "Browse"
        case .recentlyAdded: return "Recently Added"
        case .topResult: return nil
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .episodes: return "Episodes"
        }
    }
}

struct GenreSource: Hashable, Sendable {
    let sectionId: String
    let key: String
}

struct SearchGenre: Hashable, Sendable {
    let title: String
    let sources: [GenreSource]
}

enum SearchItem: Hashable {
    case recent(String)
    case genre(SearchGenre)
    case recentlyAdded(PlexMetadata)
    case top(PlexMetadata)
    case movie(PlexMetadata)
    case show(PlexMetadata)
    case episode(PlexMetadata)

    var metadata: PlexMetadata? {
        switch self {
        case .recent, .genre: return nil
        case .recentlyAdded(let m), .top(let m), .movie(let m), .show(let m), .episode(let m): return m
        }
    }

    var isSearchResult: Bool {
        switch self {
        case .top, .movie, .show, .episode: return true
        case .recent, .genre, .recentlyAdded: return false
        }
    }
}

struct SearchResults {
    let ordered: [PlexMetadata]

    init(hubs: [PlexHub]) {
        var seen = Set<String>()
        var flat = [PlexMetadata]()
        for hub in hubs {
            for item in hub.Metadata ?? [] where Self.supportedTypes.contains(item.mediaType) {
                if seen.insert(item.id).inserted { flat.append(item) }
            }
        }
        ordered = flat
    }

    private static let supportedTypes: Set<String> = ["movie", "show", "episode"]

    struct Parts {
        let top: PlexMetadata?
        let movies: [PlexMetadata]
        let shows: [PlexMetadata]
        let episodes: [PlexMetadata]

        var isEmpty: Bool { top == nil }
    }

    func parts(for scope: SearchScope) -> Parts {
        let visible = ordered.filter { scope.includes($0.mediaType) }
        return Parts(
            top: visible.first,
            movies: visible.filter { $0.mediaType == "movie" },
            shows: visible.filter { $0.mediaType == "show" },
            episodes: visible.filter { $0.mediaType == "episode" }
        )
    }
}

enum SearchHighlight {
    /// Marks the part of `text` that the query matched: the whole query when it occurs, otherwise each
    /// query word that does. Matching ignores case and diacritics.
    static func attributed(
        _ text: String,
        query: String?,
        font: UIFont,
        color: UIColor,
        highlightColor: UIColor = Theme.Color.accentText
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard let query, !query.isEmpty else { return result }
        for range in matchRanges(of: query, in: text) {
            result.addAttribute(.foregroundColor, value: highlightColor, range: range)
        }
        return result
    }

    private static func matchRanges(of query: String, in text: String) -> [NSRange] {
        let nsText = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let whole = nsText.range(of: query, options: options)
        if whole.location != NSNotFound { return [whole] }
        return query.split(whereSeparator: \.isWhitespace).compactMap { word in
            let range = nsText.range(of: String(word), options: options)
            return range.location == NSNotFound ? nil : range
        }
    }
}

enum GenrePalette {
    static let pairs: [(start: UInt32, end: UInt32)] = [
        (0x7A2A1A, 0xE0643A),
        (0x7A5A14, 0xE7B53A),
        (0x2A2A66, 0x6A6AE0),
        (0x0E4A52, 0x2FB8C4),
        (0x2F4A1F, 0x8FC04A),
        (0x5A1F5A, 0xD05AB8),
        (0x1F3A5A, 0x4A90D9),
        (0x1A4A3A, 0x3AD08F),
    ]

    private static let knownSlots: [String: Int] = [
        "action": 0, "adventure": 1, "drama": 2, "sci-fi": 3, "science fiction": 3, "comedy": 4,
        "animation": 5, "thriller": 6, "mystery": 7, "documentary": 7, "horror": 0, "fantasy": 2,
        "romance": 5, "crime": 6, "family": 1, "western": 1, "war": 0, "music": 5,
    ]

    /// A stable palette slot for a genre name. `String.hashValue` is randomised per launch, so the
    /// slot is derived from the unicode scalars instead.
    static func pair(for title: String) -> (start: UInt32, end: UInt32) {
        if let slot = knownSlots[title.lowercased()] { return pairs[slot] }
        let sum = title.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return pairs[sum % pairs.count]
    }
}

enum SearchLoader {
    static let maxGenres = 8
    private static let pageSize = 100
    private static let maxItemsPerSource = 2000

    static func genres(api: APIClient) async -> [SearchGenre] {
        guard let sections = try? await api.requestContainer(.sections) else { return [] }
        let sectionIds = (sections.Directory ?? [])
            .filter { $0.type == "movie" || $0.type == "show" }
            .compactMap(\.key)

        var order = [String]()
        var titles = [String: String]()
        var sources = [String: [GenreSource]]()
        for sectionId in sectionIds {
            guard let container = try? await api.requestContainer(.sectionGenres(sectionId: sectionId)) else { continue }
            for directory in container.Directory ?? [] {
                guard let key = directory.key, let title = directory.title else { continue }
                let merged = title.lowercased()
                if titles[merged] == nil {
                    titles[merged] = title
                    order.append(merged)
                }
                sources[merged, default: []].append(GenreSource(sectionId: sectionId, key: key))
            }
        }
        return order.prefix(maxGenres).compactMap { merged in
            guard let title = titles[merged], let genreSources = sources[merged] else { return nil }
            return SearchGenre(title: title, sources: genreSources)
        }
    }

    static func recentlyAdded(api: APIClient) async -> [PlexMetadata] {
        guard let container = try? await api.requestContainer(.recentlyAdded(start: 0, size: 30)) else { return [] }
        var seen = Set<String>()
        return (container.Metadata ?? []).filter {
            ["movie", "show", "season", "episode"].contains($0.mediaType) && seen.insert($0.id).inserted
        }
    }

    static func items(api: APIClient, genre: SearchGenre) async throws -> [PlexMetadata] {
        let batches = try await withThrowingTaskGroup(of: [PlexMetadata].self) { group in
            for source in genre.sources {
                group.addTask { try await allItems(api: api, source: source) }
            }
            var collected = [[PlexMetadata]]()
            for try await batch in group { collected.append(batch) }
            return collected
        }
        var seen = Set<String>()
        return batches.flatMap { $0 }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func allItems(api: APIClient, source: GenreSource) async throws -> [PlexMetadata] {
        var collected = [PlexMetadata]()
        var start = 0
        while start < maxItemsPerSource {
            try Task.checkCancellation()
            let container = try await api.requestContainer(
                .sectionItems(sectionId: source.sectionId, sort: "titleSort:asc", genre: source.key, start: start, size: pageSize)
            )
            let page = container.Metadata ?? []
            collected.append(contentsOf: page)
            let total = container.totalSize ?? 0
            start += pageSize
            if page.count < pageSize || (total > 0 && start >= total) { break }
        }
        return collected
    }
}

extension PosterContentConfiguration {
    /// Poster-with-caption configuration for any library item. Seasons and episodes are shown as the
    /// show they belong to, since that is what the user recognises.
    @MainActor static func search(_ item: PlexMetadata) -> PosterContentConfiguration {
        var config = PosterContentConfiguration()
        let downloadState = DownloadManager.shared.item(for: item.id)?.state
        config.isDownloaded = downloadState == .completed

        switch item.mediaType {
        case "show":
            config.posterPath = item.thumb
            config.title = item.title
            config.subtitle = item.year.map(String.init)
            config.placeholderIcon = "tv"
            let unwatched = (item.leafCount ?? 0) - (item.viewedLeafCount ?? 0)
            config.unwatchedCount = unwatched > 0 ? unwatched : nil
        case "season":
            config.posterPath = item.thumb ?? item.parentThumb
            config.title = item.parentTitle ?? item.title
            config.subtitle = item.title
            config.placeholderIcon = "tv"
        case "episode":
            config.posterPath = item.grandparentThumb ?? item.thumb
            config.title = item.grandparentTitle ?? item.title
            config.subtitle = [SearchFormat.episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · ")
            config.placeholderIcon = "tv"
            config.progress = item.progressPercent > 0 ? item.progressPercent : nil
            config.isUnwatched = !item.isWatched
        default:
            config.posterPath = item.thumb
            config.title = item.title
            config.subtitle = item.year.map(String.init)
            config.progress = item.progressPercent > 0 ? item.progressPercent : nil
            config.isUnwatched = !item.isWatched && item.progressPercent == 0
        }
        return config
    }
}

enum SearchFormat {
    static func episodeCode(_ item: PlexMetadata) -> String? {
        guard let season = item.parentIndex, let episode = item.index else { return nil }
        return "S\(season) E\(episode)"
    }

    static func typeLine(for item: PlexMetadata) -> String {
        var parts = [String]()
        switch item.mediaType {
        case "show":
            parts.append("Show")
            if let year = item.year { parts.append("\(year)") }
            if let seasons = item.childCount, seasons > 0 {
                parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons")
            }
        case "episode":
            parts.append("Episode")
            if let code = episodeCode(item) { parts.append(code) }
            if let show = item.grandparentTitle { parts.append(show) }
        default:
            parts.append("Movie")
            if let year = item.year { parts.append("\(year)") }
            let duration = Formatters.duration(item.durationSecs)
            if !duration.isEmpty { parts.append(duration) }
        }
        return parts.joined(separator: " · ")
    }
}
