import CrucibleCore
import Foundation
import GRDB
import MidgarCore

/// Where a Statistics page draws its plays from: the Plex server's history, or everything the viewer watched as Trakt
/// knows it, which adds what was watched in other apps, on streaming services and at the cinema.
package enum StatsSource: String, CaseIterable, Sendable {
    case plex
    case everything

    package var title: String {
        switch self {
        case .plex: return "Plex"
        case .everything: return String(localized: "Everything", comment: "Statistics source: Plex plays together with everything Trakt recorded")
        }
    }

    package var accessibilityLabel: String {
        switch self {
        case .plex: return String(localized: "Plex history only", comment: "VoiceOver label of the Plex statistics source")
        case .everything: return String(localized: "Everything you watched, from Trakt", comment: "VoiceOver label of the Everything statistics source")
        }
    }
}

/// One play from the viewer's Trakt history as the Statistics mirror keeps it: Trakt's own keys, outside numbers and artwork,
/// the local-time buckets every chart groups by, and, once matched, the Plex play it duplicates or the Plex keys it shares a
/// title with.
struct TraktPlayRow: Sendable, Equatable {
    var id: Int64
    var traktKey: String
    var traktShowKey: String?
    var type: String
    var title: String?
    var showTitle: String?
    var season: Int?
    var episode: Int?
    var viewedAt: Int
    var traktThumb: String?
    var traktShowThumb: String?
    var releaseYear: Int?
    var runtimeMinutes: Int?
    var genres: [String]
    /// The movie's or the episode's IMDb, TMDB and TVDB numbers.
    var ids: ExternalIDs
    /// The show's IMDb, TMDB and TVDB numbers, for an episode.
    var showIDs: ExternalIDs

    /// The row for a history entry, or nil for an entry that is neither a movie nor an episode, or has no usable date or id.
    init?(_ entry: TraktHistoryEntry) {
        guard let viewedAt = entry.watchedAtSeconds else { return nil }
        self.id = entry.id
        self.viewedAt = viewedAt
        switch entry.type {
        case "movie":
            guard let movie = entry.movie, let trakt = movie.ids.trakt else { return nil }
            type = "movie"
            traktKey = "trakt:movie:\(trakt)"
            traktShowKey = nil
            title = movie.title
            showTitle = nil
            season = nil
            episode = nil
            traktThumb = movie.images?.posterURL
            traktShowThumb = nil
            releaseYear = movie.year
            runtimeMinutes = movie.runtime
            genres = movie.genres ?? []
            ids = ExternalIDs(tvdb: nil, tmdb: movie.ids.tmdb, imdb: movie.ids.imdb)
            showIDs = ExternalIDs()
        case "episode":
            guard let item = entry.episode, let trakt = item.ids.trakt, let show = entry.show else { return nil }
            type = "episode"
            traktKey = "trakt:episode:\(trakt)"
            traktShowKey = show.ids.trakt.map { "trakt:show:\($0)" }
            title = item.title
            showTitle = show.title
            season = item.season
            episode = item.number
            traktShowThumb = show.images?.posterURL
            traktThumb = item.images?.stillURL ?? traktShowThumb
            releaseYear = show.year
            runtimeMinutes = item.runtime
            genres = show.genres ?? []
            ids = ExternalIDs(tvdb: item.ids.tvdb, tmdb: item.ids.tmdb, imdb: item.ids.imdb)
            showIDs = ExternalIDs(tvdb: show.ids.tvdb, tmdb: show.ids.tmdb, imdb: show.ids.imdb)
        default:
            return nil
        }
    }

    init(
        id: Int64, traktKey: String, traktShowKey: String?, type: String, title: String?, showTitle: String?, season: Int?, episode: Int?,
        viewedAt: Int, traktThumb: String? = nil, traktShowThumb: String? = nil, releaseYear: Int? = nil, runtimeMinutes: Int? = nil,
        genres: [String] = [], ids: ExternalIDs = ExternalIDs(), showIDs: ExternalIDs = ExternalIDs()
    ) {
        self.id = id
        self.traktKey = traktKey
        self.traktShowKey = traktShowKey
        self.type = type
        self.title = title
        self.showTitle = showTitle
        self.season = season
        self.episode = episode
        self.viewedAt = viewedAt
        self.traktThumb = traktThumb
        self.traktShowThumb = traktShowThumb
        self.releaseYear = releaseYear
        self.runtimeMinutes = runtimeMinutes
        self.genres = genres
        self.ids = ids
        self.showIDs = showIDs
    }
}

/// How Trakt's plays line up with Plex's. Two titles are the same when they share an IMDb, TMDB or TVDB number, or, while a
/// side's numbers are not known yet, when their names match and no number or release year says otherwise. A Trakt play of
/// the same title within a few hours of a Plex play is that play (Crucible or another app sent it to Trakt) and is left out
/// of Everything; any other Trakt play of a title the Plex history also has takes that title's Plex keys, artwork and
/// library, so a show watched partly on Plex and partly elsewhere is one show.
enum TraktPlayMatcher {
    /// How far apart Plex and Trakt may date the same viewing: Plex marks it watched near the end, Trakt when it stopped.
    static let window = 6 * 3600

    struct PlexPlay: Sendable {
        let id: Int64
        let ratingKey: String
        let type: String
        let title: String?
        let showTitle: String?
        let showKey: String?
        let thumb: String?
        let showThumb: String?
        let season: Int?
        let episode: Int?
        let viewedAt: Int
        let releaseYear: Int?
        var librarySectionID: Int? = nil
        var librarySectionTitle: String? = nil
        var ids = ExternalIDs()
        var showIDs = ExternalIDs()
    }

    /// What a Trakt play takes from the Plex history: the play it duplicates, or the keys, artwork and library of the title
    /// it shares, so a library left out of Statistics leaves out its plays from elsewhere too.
    struct Link: Equatable, Sendable {
        var matchedPlayID: Int64?
        var ratingKey: String
        var showKey: String?
        var thumb: String?
        var showThumb: String?
        var librarySectionID: Int? = nil
        var librarySectionTitle: String? = nil

        mutating func adoptLibrary(of play: PlexPlay) {
            librarySectionID = play.librarySectionID
            librarySectionTitle = play.librarySectionTitle
        }
    }

    /// The title as both services spell it alike: lower case, no accents, no bracketed year or country, letters and digits only,
    /// without a leading "the".
    static func normalized(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        var text = withoutBrackets(title.lowercased().folding(options: .diacriticInsensitive, locale: nil))
        text = text.replacingOccurrences(of: "&", with: "and")
        text = String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        if text.hasPrefix("the"), text.count > 3 { text.removeFirst(3) }
        return text
    }

    /// `text` without anything in round brackets, such as "(US)" or "(2005)".
    private static func withoutBrackets(_ text: String) -> String {
        var depth = 0
        var kept = ""
        for character in text {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                kept.append(character)
            }
        }
        return kept
    }

    /// The lookup keys of a set of outside numbers, one per number known.
    static func keys(_ ids: ExternalIDs) -> [String] {
        var keys: [String] = []
        if let tvdb = ids.tvdb { keys.append("tvdb:\(tvdb)") }
        if let tmdb = ids.tmdb { keys.append("tmdb:\(tmdb)") }
        if let imdb = ids.imdb, !imdb.isEmpty { keys.append("imdb:\(imdb)") }
        return keys
    }

    /// Whether two titles that share a name can still be one title: no outside number that both sides know disagrees.
    static func compatible(_ a: ExternalIDs, _ b: ExternalIDs) -> Bool {
        if let x = a.tvdb, let y = b.tvdb, x != y { return false }
        if let x = a.tmdb, let y = b.tmdb, x != y { return false }
        if let x = a.imdb, let y = b.imdb, !x.isEmpty, !y.isEmpty, x != y { return false }
        return true
    }

    /// The Plex history, indexed by outside number, by name and by season and episode within a show.
    private struct PlexIndex {
        var movieKeys: [String: [String]] = [:]
        var movieTitles: [String: [String]] = [:]
        var movies: [String: [PlexPlay]] = [:]
        var showKeys: [String: [String]] = [:]
        var showTitles: [String: [String]] = [:]
        var shows: [String: PlexPlay] = [:]
        var episodeKeys: [String: [PlexPlay]] = [:]
        var episodesByShow: [String: [String: [PlexPlay]]] = [:]

        init(_ plex: [PlexPlay]) {
            for play in plex {
                switch play.type {
                case "movie":
                    if movies[play.ratingKey] == nil {
                        for key in TraktPlayMatcher.keys(play.ids) { movieKeys[key, default: []].append(play.ratingKey) }
                        let title = TraktPlayMatcher.normalized(play.title)
                        if !title.isEmpty { movieTitles[title, default: []].append(play.ratingKey) }
                    }
                    movies[play.ratingKey, default: []].append(play)
                case "episode":
                    for key in TraktPlayMatcher.keys(play.ids) { episodeKeys[key, default: []].append(play) }
                    guard let show = play.showKey else { continue }
                    if shows[show] == nil {
                        shows[show] = play
                        for key in TraktPlayMatcher.keys(play.showIDs) { showKeys[key, default: []].append(show) }
                        let title = TraktPlayMatcher.normalized(play.showTitle)
                        if !title.isEmpty { showTitles[title, default: []].append(show) }
                    }
                    if let season = play.season, let episode = play.episode {
                        episodesByShow[show, default: [:]]["\(season)|\(episode)", default: []].append(play)
                    }
                default:
                    continue
                }
            }
        }

        /// The Plex movies a Trakt movie play is of, those sharing an outside number first.
        func movies(for row: TraktPlayRow) -> [String] {
            var found = Self.unique(TraktPlayMatcher.keys(row.ids).flatMap { movieKeys[$0] ?? [] })
            for key in movieTitles[TraktPlayMatcher.normalized(row.title)] ?? [] where !found.contains(key) {
                guard let sample = movies[key]?.first, TraktPlayMatcher.compatible(sample.ids, row.ids) else { continue }
                if let plexYear = sample.releaseYear, let traktYear = row.releaseYear, plexYear != traktYear { continue }
                found.append(key)
            }
            return found
        }

        /// The Plex shows a Trakt episode play belongs to, those sharing an outside number first.
        func shows(for row: TraktPlayRow) -> [String] {
            var found = Self.unique(TraktPlayMatcher.keys(row.showIDs).flatMap { showKeys[$0] ?? [] })
            for key in showTitles[TraktPlayMatcher.normalized(row.showTitle)] ?? [] where !found.contains(key) {
                guard let sample = shows[key], TraktPlayMatcher.compatible(sample.showIDs, row.showIDs) else { continue }
                found.append(key)
            }
            return found
        }

        /// The Plex plays of the same episode: by its own outside numbers, or by season and number within the same show.
        func episodePlays(for row: TraktPlayRow, shows: [String]) -> [PlexPlay] {
            var plays = TraktPlayMatcher.keys(row.ids).flatMap { episodeKeys[$0] ?? [] }
            if let season = row.season, let episode = row.episode {
                for show in shows {
                    plays += (episodesByShow[show]?["\(season)|\(episode)"] ?? []).filter { TraktPlayMatcher.compatible($0.ids, row.ids) }
                }
            }
            var seen = Set<Int64>()
            return plays.filter { seen.insert($0.id).inserted }
        }

        private static func unique(_ keys: [String]) -> [String] {
            var seen = Set<String>()
            return keys.filter { seen.insert($0).inserted }
        }
    }

    /// The link of every Trakt play, by its id. Each Trakt play, oldest first, pairs with the earliest Plex play of the same
    /// title still free within the window, which pairs as many as can be paired; a second Trakt record of a viewing already
    /// paired (Trakt's own Plex sync and Crucible both recorded it) is that viewing too.
    static func links(trakt: [TraktPlayRow], plex: [PlexPlay]) -> [Int64: Link] {
        let index = PlexIndex(plex)
        var used = Set<Int64>()
        var paired: [String: [(viewedAt: Int, play: PlexPlay)]] = [:]
        var result: [Int64: Link] = [:]
        var unpaired: [(row: TraktPlayRow, link: Link)] = []
        for row in trakt.sorted(by: { ($0.viewedAt, $0.id) < ($1.viewedAt, $1.id) }) {
            let adopted = adopt(row, from: index)
            var link = adopted.link
            let candidates = adopted.plays
            let twin = candidates
                .filter { !used.contains($0.id) && abs($0.viewedAt - row.viewedAt) <= window }
                .min { ($0.viewedAt, $0.id) < ($1.viewedAt, $1.id) }
            if let twin {
                used.insert(twin.id)
                link.matchedPlayID = twin.id
                paired[row.traktKey, default: []].append((row.viewedAt, twin))
                result[row.id] = link
            } else {
                unpaired.append((row, link))
            }
        }
        for (row, var link) in unpaired {
            let viewing = paired[row.traktKey]?.first { abs($0.play.viewedAt - row.viewedAt) <= window && abs($0.viewedAt - row.viewedAt) <= window }
            link.matchedPlayID = viewing?.play.id
            result[row.id] = link
        }
        return result
    }

    /// The Plex keys, artwork and library `row` takes from the Plex title it shares, and that title's Plex plays.
    private static func adopt(_ row: TraktPlayRow, from index: PlexIndex) -> (link: Link, plays: [PlexPlay]) {
        var link = Link(matchedPlayID: nil, ratingKey: row.traktKey, showKey: row.traktShowKey, thumb: row.traktThumb, showThumb: row.traktShowThumb)
        switch row.type {
        case "movie":
            let movies = index.movies(for: row)
            if let movie = movies.first.flatMap({ index.movies[$0]?.first }) {
                link.ratingKey = movie.ratingKey
                link.thumb = movie.thumb ?? link.thumb
                link.adoptLibrary(of: movie)
            }
            return (link, movies.flatMap { index.movies[$0] ?? [] })
        case "episode":
            let shows = index.shows(for: row)
            let plays = index.episodePlays(for: row, shows: shows)
            if let episode = plays.first {
                link.ratingKey = episode.ratingKey
                link.thumb = episode.thumb ?? link.thumb
                link.adoptLibrary(of: episode)
            }
            if let show = (plays.first?.showKey ?? shows.first).flatMap({ index.shows[$0] }) {
                link.showKey = show.showKey
                link.showThumb = show.showThumb ?? link.showThumb
                if link.librarySectionID == nil { link.adoptLibrary(of: show) }
            }
            return (link, plays)
        default:
            return (link, [])
        }
    }
}

/// Where the import of the viewer's Trakt history stands, for one Trakt account. A pass reads the history newest first, a page
/// at a time, from `passStartAt` (nil for the whole history); `nextPage` is where the pass continues after an interruption.
struct TraktSyncState: Sendable {
    var owner: String?
    var newestViewedAt: Int?
    var nextPage = 1
    var complete = false
    var passStartAt: Int?
}

/// The import stopped because the mirror was handed to another viewer or Trakt was disconnected while it ran.
struct TraktImportEnded: Error {}

extension StatsStore {
    /// The import state for `owner`; another account's plays are forgotten first, since the mirror holds one viewer's history.
    func traktSyncState(owner: String) async throws -> TraktSyncState {
        try await dbQueue.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT owner, newestViewedAt, nextPage, complete, passStartAt FROM trakt_sync WHERE id = 1")
            if let row, (row["owner"] as String?) == owner {
                return TraktSyncState(
                    owner: owner, newestViewedAt: row["newestViewedAt"], nextPage: row["nextPage"], complete: row["complete"],
                    passStartAt: row["passStartAt"]
                )
            }
            try Self.forgetTrakt(db)
            try db.execute(sql: "INSERT INTO trakt_sync (id, owner, nextPage, complete) VALUES (1, ?, 1, 0)", arguments: [owner])
            return TraktSyncState(owner: owner)
        }
    }

    func saveTraktSyncState(_ state: TraktSyncState) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE trakt_sync SET newestViewedAt = ?, nextPage = ?, complete = ?, passStartAt = ?, lastSyncAt = ? WHERE id = 1 AND owner = ?
                """, arguments: [state.newestViewedAt, state.nextPage, state.complete, state.passStartAt, Int(Date().timeIntervalSince1970), state.owner])
        }
    }

    private static func importOwner(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT owner FROM trakt_sync WHERE id = 1")
    }

    /// Whether Everything still lacks part of the viewer's Trakt history: the first pass over it has not finished.
    static func traktImportPending(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT complete FROM trakt_sync WHERE id = 1") != true
    }

    /// Keeps `rows` for `owner`, with their runtimes and genres where no Plex enrichment speaks for the title, and takes Trakt's
    /// word again for a play it sent before, since a viewer can correct a date or an episode on trakt.tv. Returns the newest
    /// play. Throws ``TraktImportEnded`` once the mirror no longer belongs to `owner` (Trakt was disconnected or another
    /// viewer took over mid-import), so a running import never writes an account's plays back after they were forgotten.
    @discardableResult
    func saveTraktPlays(_ rows: [TraktPlayRow], owner: String) async throws -> Int? {
        let time = StatsTime()
        let now = Int(Date().timeIntervalSince1970)
        return try await dbQueue.write { db in
            guard try Self.importOwner(db) == owner else { throw TraktImportEnded() }
            for row in rows {
                try Self.upsert(row, time: time, now: now, in: db)
            }
            return rows.map(\.viewedAt).max()
        }
    }

    private static func upsert(_ row: TraktPlayRow, time: StatsTime, now: Int, in db: Database) throws {
        let c = time.components(forViewedAt: row.viewedAt)
        try db.execute(sql: """
            INSERT INTO trakt_play (id, traktKey, traktShowKey, ratingKey, type, title, grandparentTitle, grandparentRatingKey,
                thumb, grandparentThumb, traktThumb, traktShowThumb, releaseYear, imdb, tmdb, tvdb, showImdb, showTmdb, showTvdb,
                parentIndex, idx, viewedAt, dayEpoch, hourLocal, weekday, monthEpoch, monthDay, year)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET traktKey = excluded.traktKey, traktShowKey = excluded.traktShowKey, type = excluded.type,
                title = excluded.title, grandparentTitle = excluded.grandparentTitle, traktThumb = excluded.traktThumb,
                traktShowThumb = excluded.traktShowThumb, releaseYear = excluded.releaseYear, imdb = excluded.imdb,
                tmdb = excluded.tmdb, tvdb = excluded.tvdb, showImdb = excluded.showImdb, showTmdb = excluded.showTmdb,
                showTvdb = excluded.showTvdb, parentIndex = excluded.parentIndex, idx = excluded.idx, viewedAt = excluded.viewedAt,
                dayEpoch = excluded.dayEpoch, hourLocal = excluded.hourLocal, weekday = excluded.weekday,
                monthEpoch = excluded.monthEpoch, monthDay = excluded.monthDay, year = excluded.year
            """, arguments: [
                row.id, row.traktKey, row.traktShowKey, row.traktKey, row.type, row.title, row.showTitle, row.traktShowKey,
                row.traktThumb, row.traktShowThumb, row.traktThumb, row.traktShowThumb, row.releaseYear,
                row.ids.imdb, row.ids.tmdb, row.ids.tvdb, row.showIDs.imdb, row.showIDs.tmdb, row.showIDs.tvdb,
                row.season, row.episode, row.viewedAt, c.dayEpoch, c.hourLocal, c.weekday, c.monthEpoch, c.monthDay, c.year,
            ])
        if let minutes = row.runtimeMinutes, minutes > 0 {
            try db.execute(sql: """
                INSERT OR IGNORE INTO item_meta (ratingKey, durationMs, year, enrichedAt) VALUES (?, ?, ?, ?)
                """, arguments: [row.traktKey, minutes * 60_000, row.releaseYear, now])
        }
        let owner = row.traktShowKey ?? row.traktKey
        for genre in row.genres {
            try db.execute(sql: "INSERT OR IGNORE INTO genre_link (ownerKey, genre) VALUES (?, ?)", arguments: [owner, genreTitle(genre)])
        }
        if let show = row.traktShowKey, let title = row.showTitle {
            try db.execute(sql: """
                INSERT OR IGNORE INTO show_meta (ratingKey, leafCount, title, thumb, enrichedAt) VALUES (?, NULL, ?, ?, ?)
                """, arguments: [show, title, row.traktShowThumb, now])
        }
    }

    /// Matches every Trakt play against the viewer's Plex history again (`TraktPlayMatcher`): the Plex mirror grows and learns
    /// its titles' outside numbers, so a play that stood alone yesterday may be a Plex play today.
    func linkTraktPlays() async throws {
        try await dbQueue.write { db in
            let plex = try Self.plexPlaysForMatching(db)
            let trakt = try Self.traktPlaysForMatching(db)
            for (id, link) in TraktPlayMatcher.links(trakt: trakt, plex: plex) {
                try db.execute(sql: """
                    UPDATE trakt_play SET matchedPlayID = ?, ratingKey = ?, grandparentRatingKey = ?, thumb = ?, grandparentThumb = ?,
                        librarySectionID = ?, librarySectionTitle = ? WHERE id = ?
                    """, arguments: [
                        link.matchedPlayID, link.ratingKey, link.showKey, link.thumb, link.showThumb, link.librarySectionID, link.librarySectionTitle, id,
                    ])
            }
        }
    }

    /// The viewer's own Plex plays of movies and episodes, with their release years and outside numbers where known.
    private static func plexPlaysForMatching(_ db: Database) throws -> [TraktPlayMatcher.PlexPlay] {
        let account = try scope(db).accountID.map { " AND p.accountID = \($0)" } ?? ""
        return try Row.fetchAll(db, sql: """
            SELECT p.id, p.ratingKey, p.type, p.title, p.grandparentTitle, p.grandparentRatingKey, p.thumb, p.grandparentThumb,
                   p.parentIndex, p.idx, p.viewedAt, p.librarySectionID, p.librarySectionTitle, im.year AS releaseYear,
                   ii.imdb, ii.tmdb, ii.tvdb, si.imdb AS showImdb, si.tmdb AS showTmdb, si.tvdb AS showTvdb
            FROM play p
            LEFT JOIN item_meta im ON im.ratingKey = p.ratingKey
            LEFT JOIN item_ids ii ON ii.ratingKey = p.ratingKey
            LEFT JOIN item_ids si ON si.ratingKey = p.grandparentRatingKey
            WHERE p.type IN ('movie', 'episode')\(account)
            """).map { row in
            TraktPlayMatcher.PlexPlay(
                id: row["id"], ratingKey: row["ratingKey"], type: row["type"], title: row["title"], showTitle: row["grandparentTitle"],
                showKey: row["grandparentRatingKey"], thumb: row["thumb"], showThumb: row["grandparentThumb"],
                season: row["parentIndex"], episode: row["idx"], viewedAt: row["viewedAt"], releaseYear: row["releaseYear"],
                librarySectionID: row["librarySectionID"], librarySectionTitle: row["librarySectionTitle"],
                ids: ExternalIDs(tvdb: row["tvdb"], tmdb: row["tmdb"], imdb: row["imdb"]),
                showIDs: ExternalIDs(tvdb: row["showTvdb"], tmdb: row["showTmdb"], imdb: row["showImdb"])
            )
        }
    }

    private static func traktPlaysForMatching(_ db: Database) throws -> [TraktPlayRow] {
        try Row.fetchAll(db, sql: """
            SELECT id, traktKey, traktShowKey, type, title, grandparentTitle, parentIndex, idx, viewedAt, traktThumb, traktShowThumb,
                   releaseYear, imdb, tmdb, tvdb, showImdb, showTmdb, showTvdb
            FROM trakt_play
            """).map { row in
            TraktPlayRow(
                id: row["id"], traktKey: row["traktKey"], traktShowKey: row["traktShowKey"], type: row["type"], title: row["title"],
                showTitle: row["grandparentTitle"], season: row["parentIndex"], episode: row["idx"], viewedAt: row["viewedAt"],
                traktThumb: row["traktThumb"], traktShowThumb: row["traktShowThumb"], releaseYear: row["releaseYear"],
                ids: ExternalIDs(tvdb: row["tvdb"], tmdb: row["tmdb"], imdb: row["imdb"]),
                showIDs: ExternalIDs(tvdb: row["showTvdb"], tmdb: row["showTmdb"], imdb: row["showImdb"])
            )
        }
    }

    /// Trakt's plays that Plex does not have: what Everything adds.
    func traktOnlyPlayCount() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trakt_play WHERE matchedPlayID IS NULL") ?? 0
        }
    }

    /// Forgets the viewer's Trakt history: Trakt was disconnected, or another account connected.
    func clearTrakt() async throws {
        try await dbQueue.write { db in try Self.forgetTrakt(db) }
    }

    private static func forgetTrakt(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM item_meta WHERE ratingKey LIKE 'trakt:%'")
        try db.execute(sql: "DELETE FROM genre_link WHERE ownerKey LIKE 'trakt:%'")
        try db.execute(sql: "DELETE FROM show_meta WHERE ratingKey LIKE 'trakt:%'")
        try db.execute(sql: "DELETE FROM trakt_play")
        try db.execute(sql: "DELETE FROM trakt_sync")
    }

    /// A Trakt genre slug as Plex names genres: "science-fiction" becomes "Science Fiction".
    static func genreTitle(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Remembers the IMDb, TMDB and TVDB numbers Plex holds for an item or a show; one without any is remembered as checked,
    /// so it is not asked for again.
    func saveItemIDs(_ ratingKey: String, ids: ExternalIDs) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO item_ids (ratingKey, imdb, tmdb, tvdb, checkedAt) VALUES (?, ?, ?, ?, ?)
                """, arguments: [ratingKey, ids.imdb, ids.tmdb, ids.tvdb, Int(Date().timeIntervalSince1970)])
        }
    }

    /// Played movies, episodes and their shows whose outside numbers are not known yet, most recently played first.
    func itemsNeedingIDs(limit: Int) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT k FROM (
                    SELECT ratingKey AS k, MAX(viewedAt) AS v FROM play WHERE type IN ('movie', 'episode') GROUP BY ratingKey
                    UNION ALL
                    SELECT grandparentRatingKey AS k, MAX(viewedAt) AS v FROM play
                    WHERE type = 'episode' AND grandparentRatingKey IS NOT NULL GROUP BY grandparentRatingKey
                )
                WHERE k NOT IN (SELECT ratingKey FROM item_ids)
                ORDER BY v DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }
}

/// Brings the viewer's Trakt history into the Statistics mirror: the whole history once, then only what is new, a page at a
/// time with the place kept after every page, so an interrupted pass continues where it stopped. The plays are matched against
/// the Plex history after every run, whether Trakt answered or not, since the Plex mirror may have grown.
struct TraktStatsImport {
    static let pageSize = 100
    /// Pages one run reads at most; a longer history continues on the next launch.
    static let pagesPerRun = 100
    /// How far back a pass looks again for plays Trakt filed late, such as one sent from a device that was offline.
    static let overlap = 3 * 86_400

    let store: StatsStore
    let client: TraktClient
    let owner: String

    func run() async {
        do {
            try await importHistory()
        } catch is TraktImportEnded {
            MidgarLog.info("Trakt history import ended: the mirror changed hands", category: .stats)
            return
        } catch {
            MidgarLog.notice("Trakt history not brought into Statistics: \(error.localizedDescription)", category: .stats)
        }
        do {
            try await store.linkTraktPlays()
        } catch {
            MidgarLog.notice("Trakt plays not matched against Plex: \(error.localizedDescription)", category: .stats)
        }
    }

    /// Reads pages until the pass ends or this run's share is used, keeping the place after every page.
    private func importHistory() async throws {
        var state = try await store.traktSyncState(owner: owner)
        if state.nextPage <= 1 {
            state.nextPage = 1
            state.passStartAt = state.complete ? state.newestViewedAt.map { $0 - Self.overlap } : nil
        }
        let startAt = state.passStartAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        for _ in 0..<Self.pagesPerRun {
            guard !Task.isCancelled else { break }
            let page = state.nextPage
            let (entries, pageCount) = try await client.page(.history(page: page, limit: Self.pageSize, startAt: startAt), as: [TraktHistoryEntry].self)
            if let latest = try await store.saveTraktPlays(entries.compactMap(TraktPlayRow.init), owner: owner) {
                state.newestViewedAt = max(state.newestViewedAt ?? latest, latest)
            }
            let finished = entries.isEmpty || page >= (pageCount ?? page)
            if finished {
                state.complete = true
                state.nextPage = 1
                state.passStartAt = nil
            } else {
                state.nextPage = page + 1
            }
            try await store.saveTraktSyncState(state)
            if finished { break }
        }
        MidgarLog.info("Trakt history in Statistics: complete=\(state.complete) next page \(state.nextPage)", category: .stats)
    }
}
