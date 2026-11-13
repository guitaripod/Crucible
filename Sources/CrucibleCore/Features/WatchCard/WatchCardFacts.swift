import Foundation

/// What a watch card is about: one movie or episode, a whole season, or a whole show.
package enum WatchCardScope: String, CaseIterable, Hashable, Sendable {
    case movie, episode, season, show
}

/// A title loaded for a card: the item itself, the show it belongs to, and the seasons and episodes its counts and dates
/// come from, with whatever Trakt scores the title.
package struct WatchCardSubject: Sendable {
    package let scope: WatchCardScope
    package let item: PlexMetadata
    package let show: PlexMetadata?
    package let seasons: [PlexMetadata]
    package let episodes: [PlexMetadata]
    package let scores: [TraktScore]

    package init(
        scope: WatchCardScope,
        item: PlexMetadata,
        show: PlexMetadata? = nil,
        seasons: [PlexMetadata] = [],
        episodes: [PlexMetadata] = [],
        scores: [TraktScore] = []
    ) {
        self.scope = scope
        self.item = item
        self.show = show
        self.seasons = seasons
        self.episodes = episodes
        self.scores = scores
    }
}

/// Everything a watch card says about its title, worked out once so every format and style draws the same words.
package struct WatchCardFacts: Equatable, Sendable {
    /// How much of a season or show was watched: one segment per episode of a season, one per season of a show, each the
    /// share of it that was watched.
    package struct Progress: Equatable, Sendable {
        package let segments: [Double]
        package let watched: Int
        package let total: Int
        package let label: String

        package var isComplete: Bool { total > 0 && watched >= total }
    }

    package static let genreLimit = 3
    package static let scoreLimit = 3
    package static let factLimit = 4

    package let scope: WatchCardScope
    package let ratingKey: String
    package let eyebrow: String
    package let title: String
    package let context: String?
    package let facts: [String]
    package let genres: [String]
    package let credit: String?
    package let scores: [DetailRating]
    package let servedRating: UserRating?
    package let watched: [String]
    package let progress: Progress?
    package let posterPath: String?
    package let backdropPath: String?
    package let placeholderSymbol: String
    package let shareTitle: String

    package init(subject: WatchCardSubject, calendar: Calendar = .current, locale: Locale = Formatters.interfaceLocale) {
        let item = subject.item
        let show = subject.show
        scope = subject.scope
        ratingKey = item.id
        servedRating = UserRating(plexValue: item.userRating)
        placeholderSymbol = subject.scope == .movie ? "film" : "tv"
        genres = Self.genres(item.Genre ?? show?.Genre)
        scores = Self.scores(of: subject)
        switch subject.scope {
        case .movie:
            eyebrow = WatchCardCopy.movie
            title = item.title
            context = Self.originalTitle(item)
            facts = Self.capped([item.year.map(String.init), DetailFormat.runtime(item.durationSecs), item.contentRating])
            credit = WatchCardCopy.directed(by: item.Director)
            watched = Self.watched(single: item, calendar: calendar, locale: locale)
            progress = nil
            posterPath = item.thumb
            backdropPath = item.art ?? item.thumb
            shareTitle = item.title
        case .episode:
            let code = DetailFormat.episodeCode(season: item.parentIndex, episode: item.index)
            eyebrow = code ?? WatchCardCopy.episode
            title = item.title
            context = item.grandparentTitle ?? show?.title
            let aired = Formatters.plexDate(item.originallyAvailableAt) ?? item.year.map(String.init)
            facts = Self.capped([aired, DetailFormat.runtime(item.durationSecs), item.contentRating ?? show?.contentRating])
            credit = WatchCardCopy.directed(by: item.Director)
            watched = Self.watched(single: item, calendar: calendar, locale: locale)
            progress = nil
            posterPath = item.parentThumb ?? item.grandparentThumb ?? show?.thumb ?? item.thumb
            backdropPath = item.thumb ?? item.art ?? item.grandparentArt ?? show?.art
            shareTitle = [item.title, context].compactMap { $0 }.joined(separator: " · ")
        case .season:
            let showTitle = item.parentTitle ?? show?.title ?? item.title
            let seasonTitle = ShowDetailModel.seasonTitle(item)
            let episodes = Self.episodes(subject.episodes)
            eyebrow = seasonTitle
            title = showTitle
            context = nil
            facts = Self.capped([
                item.year.map(String.init) ?? Self.yearRange(episodes),
                show?.studio,
                Self.totalRuntime(episodes),
            ])
            credit = nil
            progress = Self.seasonProgress(item: item, episodes: episodes)
            watched = Self.watched(span: episodes, finished: progress?.isComplete ?? false, calendar: calendar, locale: locale)
            posterPath = item.thumb ?? item.parentThumb ?? show?.thumb
            backdropPath = item.art ?? show?.art ?? item.thumb
            shareTitle = "\(showTitle) · \(seasonTitle)"
        case .show:
            let seasons = subject.seasons.filter { $0.mediaType == "season" && $0.index != 0 }
            let episodes = Self.episodes(subject.episodes)
            let complete = (item.leafCount ?? 0) > 0 && (item.viewedLeafCount ?? 0) >= (item.leafCount ?? 0)
            eyebrow = complete ? WatchCardCopy.completeSeries : WatchCardCopy.series
            title = item.title
            context = Self.originalTitle(item)
            let seasonCount = subject.seasons.isEmpty ? (item.childCount ?? 0) : seasons.count
            facts = Self.capped([
                Self.yearRange(episodes, from: item.year),
                item.studio,
                seasonCount > 0 ? String(localized: "\(seasonCount) Seasons") : nil,
                Self.totalRuntime(episodes),
            ])
            credit = nil
            watched = Self.watched(span: episodes, finished: complete, calendar: calendar, locale: locale)
            progress = Self.showProgress(item: item, seasons: seasons)
            posterPath = item.thumb
            backdropPath = item.art ?? item.thumb
            shareTitle = item.title
        }
    }

    /// The card read aloud, for VoiceOver on the preview: what it is, its title and its facts, the rating it carries and
    /// the viewer's words.
    package func spokenSummary(rating: UserRating?, take: String?) -> String {
        var parts = [eyebrow, title]
        if let context { parts.append(context) }
        parts.append(contentsOf: facts)
        if let rating { parts.append(UserRatingCopy.accessibilityLabel(for: rating)) }
        if let take = WatchCardTake.clean(take) { parts.append(take) }
        parts.append(contentsOf: watched)
        return parts.joined(separator: ", ")
    }

    private static func capped(_ values: [String?]) -> [String] {
        Array(values.compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }.prefix(factLimit))
    }

    private static func genres(_ tags: [PlexTag]?) -> [String] {
        var seen = Set<String>()
        return Array((tags ?? []).map(\.tag).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(genreLimit))
    }

    /// A movie's or show's own title in its original language, when it differs from the one shown.
    private static func originalTitle(_ item: PlexMetadata) -> String? {
        guard let original = item.originalTitle?.trimmingCharacters(in: .whitespaces), !original.isEmpty,
              original.caseInsensitiveCompare(item.title) != .orderedSame else { return nil }
        return original
    }

    /// The title's own scores from Plex and Trakt, as its detail page shows them, without Plex's unnamed star, which
    /// means nothing off the page.
    private static func scores(of subject: WatchCardSubject) -> [DetailRating] {
        let item = subject.item
        let ratings = DetailFormat.ratings(
            audience: named(item.audienceRating, image: item.audienceRatingImage),
            audienceImage: item.audienceRatingImage,
            critic: named(item.rating, image: item.ratingImage),
            criticImage: item.ratingImage,
            trakt: subject.scores
        )
        return Array(ratings.filter { $0.scoreSource != nil }.prefix(scoreLimit))
    }

    /// A Plex rating only when its source is one a card can draw the mark of, so an unnamed one does not take a place
    /// a named Trakt score could have.
    private static func named(_ value: Double?, image: String?) -> Double? {
        switch RatingSource(plexImage: image) {
        case .imdb, .tmdb, .rottenTomatoesCritics: return value
        case .rottenTomatoesAudience, nil: return nil
        }
    }

    private static func episodes(_ items: [PlexMetadata]) -> [PlexMetadata] {
        items.filter { $0.mediaType == "episode" }
    }

    /// The running time of every episode added up, in hours once it passes one: "8 h 12 m", "46 h".
    private static func totalRuntime(_ episodes: [PlexMetadata]) -> String? {
        let seconds = episodes.reduce(0) { $0 + $1.durationSecs }
        guard seconds >= 3_600 * 10 else { return DetailFormat.runtime(seconds) }
        return String(localized: "\(Int((seconds / 3_600).rounded())) h", comment: "Hours of a long show on a shared watch card, e.g. 46 h")
    }

    /// "2008–2013" from the show's first year to the year its last episode aired, or the one year when they match.
    private static func yearRange(_ episodes: [PlexMetadata], from start: Int? = nil) -> String? {
        let years = episodes.compactMap { episode -> Int? in
            if let date = episode.originallyAvailableAt, let year = Int(date.prefix(4)) { return year }
            return episode.year
        }
        guard let first = start ?? years.min() else { return nil }
        guard let last = years.max(), last > first else { return String(first) }
        return "\(first)–\(last)"
    }

    /// When a movie or episode was last watched, and how many times when more than once.
    private static func watched(single item: PlexMetadata, calendar: Calendar, locale: Locale) -> [String] {
        guard let viewed = item.lastViewedAt, viewed > 0 else { return [] }
        let date = Date(timeIntervalSince1970: TimeInterval(viewed))
        var lines = [WatchCardCopy.watched(on: WatchCardDates.day(date, calendar: calendar, locale: locale))]
        if let count = item.viewCount, count > 1 { lines.append(WatchCardCopy.seen(times: count)) }
        return lines
    }

    /// The days a season or show was watched across, and, once it is finished, how fast when that took two weeks at
    /// most. Plex keeps only the last time an episode was watched, so an episode watched again later would stretch the
    /// span to the rewatch: those are left out while any episode was watched just once.
    private static func watched(span episodes: [PlexMetadata], finished: Bool, calendar: Calendar, locale: Locale) -> [String] {
        let viewed = episodes.filter { ($0.lastViewedAt ?? 0) > 0 }
        let once = viewed.filter { ($0.viewCount ?? 0) <= 1 }
        let dates = (once.isEmpty ? viewed : once).compactMap { $0.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let days = WatchCardDates.daysSpanned(from: first, to: last, calendar: calendar)
        let span = WatchCardDates.span(from: first, to: last, calendar: calendar, locale: locale)
        var lines = [calendar.isDate(first, inSameDayAs: last) ? WatchCardCopy.watched(on: span) : WatchCardCopy.watched(across: span)]
        if finished, dates.count >= WatchCardDates.bingeMinimum, days <= WatchCardDates.bingeDays {
            lines.append(days == 1 ? WatchCardCopy.inOneDay : WatchCardCopy.inDays(days))
        }
        return lines
    }

    private static func seasonProgress(item: PlexMetadata, episodes: [PlexMetadata]) -> Progress? {
        let ordered = episodes.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        let total = item.leafCount ?? ordered.count
        let watched = ordered.isEmpty ? (item.viewedLeafCount ?? 0) : ordered.filter(\.isWatched).count
        guard total > 0, watched > 0 else { return nil }
        let segments = ordered.isEmpty
            ? (0..<total).map { $0 < watched ? 1.0 : 0.0 }
            : ordered.map { $0.isWatched ? 1.0 : min(1, max(0, $0.progressPercent)) }
        return Progress(segments: segments, watched: watched, total: total, label: WatchCardCopy.episodesWatched(watched, of: total))
    }

    private static func showProgress(item: PlexMetadata, seasons: [PlexMetadata]) -> Progress? {
        let total = item.leafCount ?? seasons.reduce(0) { $0 + ($1.leafCount ?? 0) }
        let watched = item.viewedLeafCount ?? seasons.reduce(0) { $0 + ($1.viewedLeafCount ?? 0) }
        guard total > 0, watched > 0 else { return nil }
        let segments = seasons
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .compactMap { season -> Double? in
                guard let leaves = season.leafCount, leaves > 0 else { return nil }
                return min(1, Double(season.viewedLeafCount ?? 0) / Double(leaves))
            }
        return Progress(segments: segments, watched: watched, total: total, label: WatchCardCopy.episodesWatched(watched, of: total))
    }
}

/// The few words a viewer adds to a card, held to a length the card has room for.
package enum WatchCardTake {
    package static let limit = 140

    /// The words as the card prints them: trimmed, on one line, nil when nothing is left.
    package static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let single = text.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}

/// Dates on a watch card, in the interface language: one day, or the days a season was watched across.
package enum WatchCardDates {
    package static let bingeDays = 14
    package static let bingeMinimum = 3

    package static func day(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    package static func span(from first: Date, to last: Date, calendar: Calendar, locale: Locale) -> String {
        guard !calendar.isDate(first, inSameDayAs: last) else { return day(first, calendar: calendar, locale: locale) }
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: first, to: last)
    }

    /// The calendar days from `first` to `last`, counting both: the same day is 1.
    package static func daysSpanned(from first: Date, to last: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: first)
        let end = calendar.startOfDay(for: last)
        return (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }
}

/// Copy for watch cards and the screen that makes them.
package enum WatchCardCopy {
    package static let movie = String(localized: "MOVIE")
    package static let episode = String(localized: "EPISODE")
    package static let series = String(localized: "TV SERIES", comment: "Label on a shared watch card for a show the viewer has not finished")
    package static let completeSeries = String(localized: "COMPLETE SERIES", comment: "Label on a shared watch card for a show the viewer has watched every episode of")
    package static let inOneDay = String(localized: "In one day", comment: "On a shared watch card: the whole season or show was watched within a single day")

    package static func directed(by directors: [PlexTag]?) -> String? {
        let names = (directors ?? []).map(\.tag).filter { !$0.isEmpty }
        guard let first = names.first else { return nil }
        let people = names.count > 1 ? String(localized: "\(first) & \(names[1])", comment: "Two directors of a film, e.g. Joel Coen & Ethan Coen") : first
        return String(localized: "Directed by \(people)", comment: "Credit line on a shared watch card, e.g. Directed by Denis Villeneuve")
    }

    package static func watched(on date: String) -> String {
        String(localized: "Watched \(date)", comment: "On a shared watch card: the day the title was watched, e.g. Watched Nov 13, 2026")
    }

    package static func watched(across span: String) -> String {
        String(
            localized: "watchCard.watchedAcross",
            defaultValue: "Watched \(span)",
            comment: "On a shared watch card: the days a season or show was watched across, a date range, e.g. Watched Oct 30 – Nov 13, 2026"
        )
    }

    package static func seen(times count: Int) -> String {
        String(localized: "Seen \(count) times", comment: "On a shared watch card: how many times the viewer has watched the movie or episode, always 2 or more")
    }

    package static func inDays(_ days: Int) -> String {
        String(localized: "In \(days) days", comment: "On a shared watch card: the season or show was watched over this many days, e.g. In 4 days")
    }

    package static func episodesWatched(_ watched: Int, of total: Int) -> String {
        watched >= total
            ? String(localized: "All \(total) episodes", comment: "On a shared watch card: every episode of the season or show was watched, e.g. All 10 episodes")
            : String(localized: "\(watched) of \(total) episodes", comment: "On a shared watch card: how many episodes of the season or show were watched, e.g. 7 of 10 episodes")
    }
}
