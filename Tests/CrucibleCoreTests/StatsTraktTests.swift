import Foundation
import Testing
@testable import CrucibleCore
@testable import CrucibleStats

/// Trakt's history in Statistics: a Trakt play of something Plex already counted is that play, a title watched partly on Plex
/// and partly elsewhere is one title, titles are told apart by their outside numbers, and Everything adds only what Plex never
/// saw.
struct StatsTraktTests {
    private let base = 1_780_000_000

    private func plexEpisode(
        _ id: Int64, show: String, season: Int, episode: Int, at viewedAt: Int, showKey: String = "show-office", showIDs: ExternalIDs = ExternalIDs()
    ) -> TraktPlayMatcher.PlexPlay {
        TraktPlayMatcher.PlexPlay(
            id: id, ratingKey: "ep-\(id)", type: "episode", title: "Episode \(episode)", showTitle: show, showKey: showKey,
            thumb: "/ep/\(id)", showThumb: "/show/\(showKey)", season: season, episode: episode, viewedAt: viewedAt, releaseYear: nil,
            showIDs: showIDs
        )
    }

    private func traktEpisode(
        _ id: Int64, show: String, season: Int, episode: Int, at viewedAt: Int, showIDs: ExternalIDs = ExternalIDs(), traktShow: Int = 1
    ) -> TraktPlayRow {
        TraktPlayRow(
            id: id, traktKey: "trakt:episode:\(traktShow)-\(season)-\(episode)", traktShowKey: "trakt:show:\(traktShow)", type: "episode",
            title: "Episode \(episode)", showTitle: show, season: season, episode: episode, viewedAt: viewedAt,
            traktShowThumb: "https://walter/show\(traktShow).jpg", runtimeMinutes: 22, showIDs: showIDs
        )
    }

    @Test func titlesAreComparedAsBothServicesSpellThem() {
        #expect(TraktPlayMatcher.normalized("The Office (US)") == TraktPlayMatcher.normalized("The Office"))
        #expect(TraktPlayMatcher.normalized("Amélie") == TraktPlayMatcher.normalized("Amelie"))
        #expect(TraktPlayMatcher.normalized("Law & Order") == TraktPlayMatcher.normalized("Law and Order"))
        #expect(TraktPlayMatcher.normalized("Doctor Who (2005)") == "doctorwho")
        #expect(TraktPlayMatcher.normalized(nil).isEmpty)
    }

    /// The first Trakt record of a Plex viewing is that viewing, and so is a second record of it hours later (Trakt's own Plex
    /// sync and Crucible both sent it); a rewatch days later is a play of its own of the same episode.
    @Test func aTraktPlayOfAPlexViewingIsThatViewing() {
        let plex = [plexEpisode(1, show: "The Office (US)", season: 2, episode: 3, at: base)]
        let trakt = [
            traktEpisode(10, show: "The Office", season: 2, episode: 3, at: base + 1_800),
            traktEpisode(11, show: "The Office", season: 2, episode: 3, at: base + 3_000),
            traktEpisode(12, show: "The Office", season: 2, episode: 3, at: base + 3 * 86_400),
        ]
        let links = TraktPlayMatcher.links(trakt: trakt, plex: plex)
        #expect(links[10]?.matchedPlayID == 1)
        #expect(links[11]?.matchedPlayID == 1, "a second record of the same viewing is that viewing")
        #expect(links[12]?.matchedPlayID == nil, "a rewatch days later is its own play")
        #expect(links[12]?.ratingKey == "ep-1", "the rewatch is the same episode")
    }

    /// Plays are paired so that as many as possible pair, not each with its nearest: two viewings of one episode on Plex at
    /// 0 h and 5 h and on Trakt at 4 h and 7 h are two pairs.
    @Test func asManyPlaysPairAsCan() {
        let plex = [
            plexEpisode(1, show: "Severance", season: 1, episode: 1, at: base, showKey: "sev"),
            plexEpisode(2, show: "Severance", season: 1, episode: 1, at: base + 5 * 3600, showKey: "sev"),
        ]
        let trakt = [
            traktEpisode(20, show: "Severance", season: 1, episode: 1, at: base + 4 * 3600),
            traktEpisode(21, show: "Severance", season: 1, episode: 1, at: base + 7 * 3600),
        ]
        let links = TraktPlayMatcher.links(trakt: trakt, plex: plex)
        #expect(Set([links[20]?.matchedPlayID, links[21]?.matchedPlayID]) == Set([1, 2]))
    }

    @Test func aShowWatchedPartlyElsewhereIsOneShow() {
        let plex = [plexEpisode(1, show: "The Office (US)", season: 2, episode: 3, at: base)]
        let trakt = [traktEpisode(20, show: "The Office", season: 2, episode: 4, at: base + 86_400)]
        let link = TraktPlayMatcher.links(trakt: trakt, plex: plex)[20]
        #expect(link?.matchedPlayID == nil)
        #expect(link?.showKey == "show-office")
        #expect(link?.showThumb == "/show/show-office")
        #expect(link?.ratingKey == "trakt:episode:1-2-4", "an episode Plex never played keeps Trakt's key")
    }

    /// Once both sides know a show's TVDB number, the British and the American Office are two shows, while a show Plex names in
    /// another language is still the one Trakt names in English.
    @Test func outsideNumbersDecideWhichShowItIs() {
        let plex = [
            plexEpisode(1, show: "The Office (US)", season: 2, episode: 3, at: base, showKey: "office-us", showIDs: ExternalIDs(tvdb: 73244)),
            plexEpisode(2, show: "Kolmas kivi auringosta", season: 1, episode: 1, at: base, showKey: "3rd-rock", showIDs: ExternalIDs(tvdb: 76198)),
        ]
        let trakt = [
            traktEpisode(30, show: "The Office", season: 2, episode: 3, at: base + 600, showIDs: ExternalIDs(tvdb: 78107), traktShow: 2),
            traktEpisode(31, show: "3rd Rock from the Sun", season: 1, episode: 1, at: base + 900, showIDs: ExternalIDs(tvdb: 76198), traktShow: 3),
        ]
        let links = TraktPlayMatcher.links(trakt: trakt, plex: plex)
        #expect(links[30]?.matchedPlayID == nil, "the British Office is not the American play")
        #expect(links[30]?.showKey == "trakt:show:2")
        #expect(links[31]?.matchedPlayID == 2, "a Finnish title with the same TVDB number is the same show")
    }

    @Test func aRemakeIsNotTheOriginal() {
        let original = TraktPlayMatcher.PlexPlay(
            id: 5, ratingKey: "dune-84", type: "movie", title: "Dune", showTitle: nil, showKey: nil, thumb: "/dune84", showThumb: nil,
            season: nil, episode: nil, viewedAt: base, releaseYear: 1984
        )
        let remake = TraktPlayRow(
            id: 30, traktKey: "trakt:movie:30", traktShowKey: nil, type: "movie", title: "Dune", showTitle: nil, season: nil, episode: nil,
            viewedAt: base + 30 * 86_400, traktThumb: "https://walter/dune21.jpg", releaseYear: 2021
        )
        let link = TraktPlayMatcher.links(trakt: [remake], plex: [original])[30]
        #expect(link?.ratingKey == "trakt:movie:30")
        #expect(link?.thumb == "https://walter/dune21.jpg")
    }

    /// A film whose year Plex has not reported yet is still told apart from its remake once the IMDb numbers differ.
    @Test func outsideNumbersTellARemakeApartWithoutAYear() {
        var original = TraktPlayMatcher.PlexPlay(
            id: 5, ratingKey: "dune-84", type: "movie", title: "Dune", showTitle: nil, showKey: nil, thumb: "/dune84", showThumb: nil,
            season: nil, episode: nil, viewedAt: base, releaseYear: nil
        )
        original.ids = ExternalIDs(imdb: "tt0087182")
        let remake = TraktPlayRow(
            id: 31, traktKey: "trakt:movie:31", traktShowKey: nil, type: "movie", title: "Dune", showTitle: nil, season: nil, episode: nil,
            viewedAt: base + 600, releaseYear: 2021, ids: ExternalIDs(tmdb: 438631, imdb: "tt1160419")
        )
        let link = TraktPlayMatcher.links(trakt: [remake], plex: [original])[31]
        #expect(link?.matchedPlayID == nil)
        #expect(link?.ratingKey == "trakt:movie:31")
    }

    /// A Trakt play of a title in a library left out of Statistics is left out with it.
    @Test func aPlayElsewhereOfAnExcludedLibrarysTitleTakesItsLibrary() {
        var play = plexEpisode(1, show: "The Office (US)", season: 2, episode: 3, at: base)
        play.librarySectionID = 9
        play.librarySectionTitle = "Kids"
        let link = TraktPlayMatcher.links(trakt: [traktEpisode(40, show: "The Office", season: 3, episode: 1, at: base + 86_400)], plex: [play])[40]
        #expect(link?.librarySectionID == 9)
        #expect(link?.librarySectionTitle == "Kids")
    }

    @Test func historyEntriesBecomeRowsWithPostersRuntimesAndIDs() throws {
        let json = #"""
        [{"id": 9001, "watched_at": "2026-11-01T20:15:00.000Z", "action": "watch", "type": "episode",
          "episode": {"season": 1, "number": 2, "title": "Pilot Two", "ids": {"trakt": 77, "tvdb": 900, "imdb": "tt9"}, "runtime": 44, "images": {"screenshot": ["walter-r2.trakt.tv/still.jpg"]}},
          "show": {"title": "Severance", "year": 2022, "ids": {"trakt": 5, "tvdb": 371980, "tmdb": 95396}, "genres": ["science-fiction", "drama"], "images": {"poster": ["walter-r2.trakt.tv/poster.jpg"]}}},
         {"id": 9002, "watched_at": "2026-11-02T21:00:00Z", "type": "movie",
          "movie": {"title": "Heat", "year": 1995, "ids": {"trakt": 8, "tmdb": 949, "imdb": "tt0113277"}, "runtime": 170, "genres": ["crime"]}}]
        """#
        let entries = try JSONDecoder().decode([TraktHistoryEntry].self, from: Data(json.utf8))
        let rows = entries.compactMap(TraktPlayRow.init)
        #expect(rows.count == 2)
        #expect(rows[0].traktShowThumb == "https://walter-r2.trakt.tv/poster.jpg")
        #expect(rows[0].traktThumb == "https://walter-r2.trakt.tv/still.jpg")
        #expect(rows[0].traktShowKey == "trakt:show:5")
        #expect(rows[0].ids == ExternalIDs(tvdb: 900, imdb: "tt9"))
        #expect(rows[0].showIDs == ExternalIDs(tvdb: 371980, tmdb: 95396))
        #expect(rows[1].runtimeMinutes == 170)
        #expect(rows[1].ids == ExternalIDs(tmdb: 949, imdb: "tt0113277"))
        #expect(StatsStore.genreTitle("science-fiction") == "Science Fiction")
    }

    private func temporaryStore() throws -> (StatsStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stats-trakt-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("Stats", isDirectory: true).appendingPathComponent("stats.sqlite")
        return (StatsStore(database: try StatsDatabase(url: url)), folder)
    }

    private func plexPlay(_ ratingKey: String, episode: Int, at viewedAt: Int, account: Int, section: Int = 1) -> Play {
        let c = StatsTime().components(forViewedAt: viewedAt)
        return Play(
            id: nil, ratingKey: ratingKey, type: "episode", title: "Episode \(episode)", grandparentTitle: "The Office (US)",
            grandparentRatingKey: "show-office", grandparentThumb: "/show/office", thumb: "/ep/\(ratingKey)", parentIndex: 2, idx: episode,
            viewedAt: viewedAt, dayEpoch: c.dayEpoch, hourLocal: c.hourLocal, weekday: c.weekday, monthEpoch: c.monthEpoch,
            monthDay: c.monthDay, year: c.year, librarySectionID: section, librarySectionTitle: "TV", accountID: account, deviceID: nil
        )
    }

    @Test func everythingAddsOnlyWhatPlexNeverSaw() async throws {
        let (store, folder) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Int(Date().timeIntervalSince1970) - 86_400
        try await store.insertPlays([plexPlay("ep-1", episode: 3, at: now, account: 1)])
        _ = try await store.traktSyncState(owner: "account")
        try await store.saveTraktPlays([
            traktEpisode(10, show: "The Office", season: 2, episode: 3, at: now + 600),
            traktEpisode(11, show: "The Office", season: 2, episode: 4, at: now + 3_600),
            TraktPlayRow(
                id: 12, traktKey: "trakt:movie:12", traktShowKey: nil, type: "movie", title: "Heat", showTitle: nil, season: nil, episode: nil,
                viewedAt: now + 7_200, traktThumb: "https://walter/heat.jpg", releaseYear: 1995, runtimeMinutes: 170, genres: ["crime"]
            ),
        ], owner: "account")
        try await store.linkTraktPlays()

        let plex = try await store.snapshot(range: .allTime, source: .plex)
        let everything = try await store.snapshot(range: .allTime, source: .everything)
        #expect(plex.overview.totalPlays == 1)
        #expect(everything.overview.totalPlays == 3, "the matched Trakt play is not counted twice")
        #expect(everything.topShows.first?.ratingKey == "show-office")
        #expect(everything.topShows.first?.count == 2, "both Office episodes count under the Plex show")
        #expect(everything.topMovies.contains { $0.title == "Heat" && $0.thumb == "https://walter/heat.jpg" })
        #expect(try await store.traktOnlyPlayCount() == 2)
        #expect(everything.traktImportPending, "the history import has not finished a pass")
        #expect(!plex.traktImportPending, "Plex's own history never waits on Trakt")

        _ = try await store.traktSyncState(owner: "another-profile")
        #expect(try await store.traktOnlyPlayCount() == 0, "another account's Trakt history is forgotten")
        let after = try await store.snapshot(range: .allTime, source: .everything)
        #expect(after.overview.totalPlays == 1)
    }

    /// On a server whose mirror holds the whole household, only the viewer's own Plex play can be the one Trakt recorded:
    /// a housemate watching the same episode that evening must not swallow the viewer's play.
    @Test func onlyTheViewersOwnPlexPlayAbsorbsTheirTraktPlay() async throws {
        let (store, folder) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Int(Date().timeIntervalSince1970) - 86_400
        try await store.insertPlays([
            plexPlay("ep-1", episode: 3, at: now, account: 1),
            plexPlay("ep-2", episode: 4, at: now + 600, account: 7),
        ])
        _ = try await store.traktSyncState(owner: "account")
        try await store.saveTraktPlays([traktEpisode(20, show: "The Office", season: 2, episode: 4, at: now + 900)], owner: "account")
        try await store.linkTraktPlays()
        #expect(try await store.traktOnlyPlayCount() == 1, "the housemate's play is not the viewer's")
        let everything = try await store.snapshot(range: .allTime, source: .everything)
        #expect(everything.overview.totalPlays == 2)
    }

    /// Disconnecting while an import runs forgets the history, and the import cannot write it back.
    @Test func anImportCannotWriteBackAfterTheHistoryWasForgotten() async throws {
        let (store, folder) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await store.traktSyncState(owner: "account")
        try await store.clearTrakt()
        await #expect(throws: TraktImportEnded.self) {
            try await store.saveTraktPlays([traktEpisode(30, show: "The Office", season: 1, episode: 1, at: base)], owner: "account")
        }
        #expect(try await store.traktOnlyPlayCount() == 0)
    }

    /// A date or episode corrected on trakt.tv replaces what the mirror kept when the play comes back in a later page.
    @Test func aCorrectionOnTraktReplacesWhatWasKept() async throws {
        let (store, folder) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await store.traktSyncState(owner: "account")
        try await store.saveTraktPlays([traktEpisode(50, show: "Severance", season: 1, episode: 1, at: base)], owner: "account")
        try await store.saveTraktPlays([traktEpisode(50, show: "Severance", season: 1, episode: 2, at: base + 86_400)], owner: "account")
        let day = try await store.plays(onDayEpoch: StatsTime().components(forViewedAt: base + 86_400).dayEpoch, source: .everything)
        let before = try await store.plays(onDayEpoch: StatsTime().components(forViewedAt: base).dayEpoch, source: .everything)
        #expect(day.map(\.title) == ["Episode 2"])
        #expect(before.isEmpty)
    }

    private func historyPage(_ entries: [(id: Int64, episode: Int, at: Int)]) -> String {
        let items = entries.map { entry in
            let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(entry.at)))
            return #"{"id": \#(entry.id), "watched_at": "\#(date)", "type": "episode", "episode": {"season": 2, "number": \#(entry.episode), "ids": {"trakt": \#(entry.id)}}, "show": {"title": "The Office", "ids": {"trakt": 1}}}"#
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// A pass keeps its place after every page: a page that fails leaves the pages before it imported, the next run continues
    /// there, the plays are matched against Plex even when Trakt did not answer, and once the history is complete a run asks
    /// only for what is new, from three days before the newest play.
    @Test func theImportKeepsItsPlaceAndMatchesWhateverTraktAnswers() async throws {
        let (store, folder) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Int(Date().timeIntervalSince1970) - 86_400
        try await store.insertPlays([plexPlay("ep-1", episode: 3, at: now, account: 1)])
        let script = TraktScript()
        let tokens = TraktTokenStore(keychain: .memory(), owner: { "account" })
        await tokens.save(TraktFixtures.token())
        let client = TraktClient(transport: script.transport, tokens: tokens, sleep: { _ in }, clientID: { "client" })
        let pages = ["X-Pagination-Page-Count": "3"]
        script.queue("/sync/history", 200, historyPage([(1, 3, now + 600)]), headers: pages)
        script.queue("/sync/history", 400, "{}")
        let importer = TraktStatsImport(store: store, client: client, owner: "account")

        await importer.run()
        var state = try await store.traktSyncState(owner: "account")
        #expect(state.nextPage == 2 && !state.complete, "the failed page is where the next run starts")
        #expect(try await store.traktOnlyPlayCount() == 0, "the imported play was matched to the Plex play although page 2 failed")

        script.queue("/sync/history", 200, historyPage([(2, 4, now - 86_400)]), headers: pages)
        script.queue("/sync/history", 200, historyPage([(3, 5, now - 2 * 86_400)]), headers: pages)
        await importer.run()
        state = try await store.traktSyncState(owner: "account")
        #expect(state.complete && state.nextPage == 1)
        #expect(state.newestViewedAt == now + 600)
        #expect(try await store.traktOnlyPlayCount() == 2)

        script.queue("/sync/history", 200, "[]", headers: ["X-Pagination-Page-Count": "1"])
        await importer.run()
        let last = try #require(script.requests.last?.url)
        let query = URLComponents(url: last, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let startAt = try #require(query.first { $0.name == "start_at" }?.value)
        #expect(ISO8601DateFormatter().date(from: startAt).map { Int($0.timeIntervalSince1970) } == now + 600 - TraktStatsImport.overlap)
        #expect(query.first { $0.name == "page" }?.value == "1")
    }
}
