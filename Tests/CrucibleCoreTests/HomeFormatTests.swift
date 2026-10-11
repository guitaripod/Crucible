import Foundation
import Testing
@testable import CrucibleCore

struct HomeFormatTests {
    private func item(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private func episode(duration: Int? = 2_640_000, viewOffset: Int? = nil) throws -> PlexMetadata {
        var fields = #""ratingKey":"7","type":"episode","title":"Low Tide","grandparentTitle":"The Show","parentTitle":"Season 2","parentIndex":2,"index":4"#
        if let duration { fields += #","duration":\#(duration)"# }
        if let viewOffset { fields += #","viewOffset":\#(viewOffset)"# }
        return try item("{\(fields)}")
    }

    private func movie() throws -> PlexMetadata {
        try item(#"{"ratingKey":"8","type":"movie","title":"Salt","year":2021,"duration":7500000}"#)
    }

    @Test func runtimeUsesHoursAndMinutes() {
        #expect(HomeFormat.runtime(7500) == "2 h 05 m")
        #expect(HomeFormat.runtime(3600) == "1 h 00 m")
        #expect(HomeFormat.runtime(2640) == "44 min")
    }

    @Test func runtimeFloorsAtOneMinuteAndRejectsNonPositiveInput() {
        #expect(HomeFormat.runtime(5) == "1 min")
        #expect(HomeFormat.runtime(0) == nil)
        #expect(HomeFormat.runtime(-30) == nil)
        #expect(HomeFormat.runtime(.nan) == nil)
        #expect(HomeFormat.runtime(.infinity) == nil)
    }

    @Test func weekTotalClampsNegativeValues() {
        #expect(HomeFormat.weekTotal(26400) == "7 h 20 m")
        #expect(HomeFormat.weekTotal(59 * 60) == "59 min")
        #expect(HomeFormat.weekTotal(-5) == "0 min")
    }

    @Test func spokenDurationHandlesTinyAndInvalidValues() {
        #expect(HomeFormat.spoken(10) == "less than a minute")
        #expect(HomeFormat.spoken(.nan) == "less than a minute")
        #expect(!HomeFormat.spoken(4320).isEmpty)
    }

    @Test func episodeLineSkipsMissingParts() {
        #expect(HomeFormat.episodeLine(season: 2, episode: 4, tail: "Low Tide") == "S2 · E4 · Low Tide")
        #expect(HomeFormat.episodeLine(season: nil, episode: 4, tail: "") == "E4")
        #expect(HomeFormat.episodeLine(season: nil, episode: nil, tail: nil) == "")
    }

    @Test func spokenEpisodeNeedsAtLeastOnePart() {
        #expect(HomeFormat.spokenEpisode(season: 2, episode: 4) == "season 2 episode 4")
        #expect(HomeFormat.spokenEpisode(season: nil, episode: 4) == "episode 4")
        #expect(HomeFormat.spokenEpisode(season: nil, episode: nil) == nil)
    }

    @Test func joinedDropsEmptyParts() {
        #expect(HomeFormat.joined(["2021", nil, "", "2 h 05 m"]) == "2021 · 2 h 05 m")
        #expect(HomeFormat.joined([nil, ""]) == nil)
    }

    @Test func remainingReportsTimeLeftOnPartiallyWatchedItems() throws {
        let partial = try episode(duration: 2_700_000, viewOffset: 600_000)
        #expect(HomeFormat.remainingSeconds(partial) == 2100)
        #expect(HomeFormat.remaining(partial) == "35 min left")
    }

    @Test func remainingIsNilWhenNothingIsLeftOrStarted() throws {
        #expect(HomeFormat.remaining(try episode(duration: 2_700_000, viewOffset: nil)) == nil)
        #expect(HomeFormat.remaining(try episode(duration: 2_700_000, viewOffset: 2_700_000)) == nil)
        #expect(HomeFormat.remaining(try episode(duration: nil, viewOffset: 1000)) == nil)
    }

    @Test func remainingNeverDropsBelowOneMinute() throws {
        let almostDone = try episode(duration: 2_700_000, viewOffset: 2_690_000)
        #expect(HomeFormat.remainingSeconds(almostDone) == 60)
    }

    @Test func titleFollowsTheItemType() throws {
        #expect(HomeFormat.title(for: try episode()) == "The Show")
        let season = try item(#"{"ratingKey":"9","type":"season","title":"Season 2","parentTitle":"The Show"}"#)
        #expect(HomeFormat.title(for: season) == "The Show")
        #expect(HomeFormat.title(for: try movie()) == "Salt")
    }

    @Test func subtitlesDifferBetweenEpisodesAndMovies() throws {
        let episode = try episode()
        let movie = try movie()
        #expect(HomeFormat.heroSubtitle(for: episode) == "S2 · E4 · Low Tide")
        #expect(HomeFormat.heroSubtitle(for: movie) == "2021 · 2 h 05 m")
        #expect(HomeFormat.continueSubtitle(for: episode) == "S2 · E4 · Low Tide")
        #expect(HomeFormat.continueSubtitle(for: movie) == "Movie · 2 h 05 m")
        #expect(HomeFormat.upNextSubtitle(for: episode) == "S2 · E4 · 44 min")
        #expect(HomeFormat.upNextSubtitle(for: movie) == "2021 · 2 h 05 m")
    }

    @Test func recentSubtitleDependsOnType() throws {
        let show = try item(#"{"ratingKey":"1","type":"show","title":"S"}"#)
        let datedShow = try item(#"{"ratingKey":"1","type":"show","title":"S","year":2019}"#)
        let season = try item(#"{"ratingKey":"2","type":"season","title":"Season 3"}"#)
        #expect(HomeFormat.recentSubtitle(for: show) == "Series")
        #expect(HomeFormat.recentSubtitle(for: datedShow) == "2019")
        #expect(HomeFormat.recentSubtitle(for: season) == "Season 3")
        #expect(HomeFormat.recentSubtitle(for: try episode()) == "S2 · E4 · Low Tide")
        #expect(HomeFormat.recentSubtitle(for: try movie()) == "2021")
    }
}

struct HomeServerRouteTests {
    private func classify(_ string: String) -> HomeServerRoute {
        HomeServerRoute.classify(URL(string: string)!)
    }

    @Test func privateAndTailscaleAddressesAreLocal() {
        #expect(classify("http://192.168.1.5:32400") == .local)
        #expect(classify("http://10.1.2.3:32400") == .local)
        #expect(classify("http://172.20.0.2:32400") == .local)
        #expect(classify("http://100.100.1.1:32400") == .local)
        #expect(classify("http://localhost:32400") == .local)
        #expect(classify("http://nas.local:32400") == .local)
    }

    @Test func publicAddressesAndNamesAreRemote() {
        #expect(classify("http://203.0.113.9:32400") == .remote)
        #expect(classify("https://plex.example.com:32400") == .remote)
        #expect(classify("http://172.32.0.1:32400") == .remote)
    }

    @Test func plexDirectNamesAreClassifiedByEmbeddedAddressAndPort() {
        #expect(classify("https://192-168-1-5.abc.plex.direct:32400") == .local)
        #expect(classify("https://203-0-113-9.abc.plex.direct:32400") == .remote)
        #expect(classify("https://203-0-113-9.abc.plex.direct:8443") == .relay)
        #expect(classify("https://203-0-113-9.abc.plex.direct") == .remote)
    }

    @Test func ipv6FollowsPrefix() {
        #expect(classify("http://[::1]:32400") == .local)
        #expect(classify("http://[fd00::5]:32400") == .local)
        #expect(classify("http://[2001:db8::1]:32400") == .remote)
    }

    @Test func titlesAndSymbolsAreStable() {
        #expect(HomeServerRoute.local.title == "Local")
        #expect(HomeServerRoute.remote.title == "Remote")
        #expect(HomeServerRoute.relay.title == "Relay")
        #expect(HomeServerRoute.local.symbol == "house")
        #expect(HomeServerRoute.remote.symbol == "globe")
        #expect(HomeServerRoute.relay.symbol == "arrow.triangle.branch")
    }
}
