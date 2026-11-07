import Foundation
import Testing
@testable import CrucibleCore

struct TopShelfCarouselTests {
    private let source = TopShelfBuilder.Source(
        serverURL: URL(string: "http://192.168.1.5:32400/")!,
        token: "tok",
        machineIdentifier: "m1",
        clientIdentifier: "client-1",
        platform: "tvOS"
    )
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func metadata(_ json: String) -> PlexMetadata {
        AuthFixtures.metadata(json)
    }

    private func episode(_ key: String, season: Int = 2, index: Int = 4, offset: Int? = nil, addedAt: Int? = nil, aired: String? = nil) -> PlexMetadata {
        let offsetJSON = offset.map { #""viewOffset": \#($0),"# } ?? ""
        let addedJSON = addedAt.map { #""addedAt": \#($0),"# } ?? ""
        let airedJSON = aired.map { #""originallyAvailableAt": "\#($0)","# } ?? ""
        return metadata("""
        {"ratingKey": "\(key)", "type": "episode", "title": "Episode \(index)", "grandparentTitle": "The Show", "grandparentRatingKey": "100",
         "parentRatingKey": "200", "parentIndex": \(season), "index": \(index), \(offsetJSON) \(addedJSON) \(airedJSON) "duration": 2700000,
         "summary": "", "grandparentArt": "/library/metadata/100/art/1", "librarySectionID": 2}
        """)
    }

    private func movie(_ key: String, offset: Int? = nil, viewCount: Int? = nil, extra: String = "") -> PlexMetadata {
        let offsetJSON = offset.map { #""viewOffset": \#($0),"# } ?? ""
        let viewJSON = viewCount.map { #""viewCount": \#($0),"# } ?? ""
        return metadata("""
        {"ratingKey": "\(key)", "type": "movie", "title": "Movie \(key)", \(offsetJSON) \(viewJSON) "duration": 7200000, "year": 2021,
         "originallyAvailableAt": "2021-01-01", "art": "/library/metadata/\(key)/art/1", "librarySectionID": 1 \(extra)}
        """)
    }

    private func show(_ key: String, leaves: Int = 10, viewed: Int = 0) -> PlexMetadata {
        metadata(#"{"ratingKey": "\#(key)", "type": "show", "title": "Show \#(key)", "leafCount": \#(leaves), "viewedLeafCount": \#(viewed), "librarySectionID": 2}"#)
    }

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func recentlyAddedFillsTheCarouselWithUnstartedTitlesNotAlreadyThere() {
        let buckets = HomeBuckets(
            continueWatching: [episode("11", offset: 600_000)],
            onDeck: [movie("21")],
            recent: [movie("21"), show("100"), movie("31"), movie("32", viewCount: 1), show("33", viewed: 10), show("36", viewed: 3), episode("34"), show("35")]
        )
        let picks = TopShelfBuilder.picks(buckets: buckets, excludedLibraries: [])

        #expect(picks.map(\.item.id) == ["11", "21", "31", "35"])
        #expect(picks.map(\.kind) == [.continueWatching, .upNext, .recentlyAdded, .recentlyAdded])
    }

    @Test func sharesGiveEachRowItsPlaceBeforeTheLeftoversAreHandedOut() {
        #expect(TopShelfBuilder.allocate([10, 10, 10], shares: [4, 4, 2], total: 10) == [4, 4, 2])
        #expect(TopShelfBuilder.allocate([1, 10, 10], shares: [4, 4, 2], total: 10) == [1, 7, 2])
        #expect(TopShelfBuilder.allocate([0, 0, 10], shares: [4, 4, 2], total: 10) == [0, 0, 10])
        #expect(TopShelfBuilder.allocate([2, 1, 0], shares: [4, 4, 2], total: 10) == [2, 1, 0])
    }

    @Test func theContextLineSaysWhyTheCardIsThere() {
        let resume = TopShelfBuilder.Pick(item: episode("11", offset: 600_000), kind: .continueWatching)
        #expect(TopShelfBuilder.contextTitle(for: resume, now: now) == "Continue Watching · 35 min left")

        let fresh = episode("12", addedAt: 1_700_000_000 - 86_400, aired: "2023-11-13")
        #expect(TopShelfBuilder.contextTitle(for: .init(item: fresh, kind: .upNext), now: now) == "New Episode")

        let premiere = episode("13", season: 3, index: 1)
        #expect(TopShelfBuilder.contextTitle(for: .init(item: premiere, kind: .upNext), now: now) == "Season Premiere")
        #expect(TopShelfBuilder.contextTitle(for: .init(item: episode("14"), kind: .upNext), now: now) == "Up Next")
        #expect(TopShelfBuilder.contextTitle(for: .init(item: movie("15"), kind: .recentlyAdded), now: now) == "Recently Added")
    }

    @Test func theDetailsFillGenreCastDirectorAndTheNextEpisode() {
        let item = episode("11", offset: 600_000)
        let showDetails = metadata("""
        {"ratingKey": "100", "type": "show", "title": "The Show", "summary": "A coast.", "Genre": [{"tag": "Drama"}, {"tag": "Mystery"}],
         "Role": [{"tag": "Ada"}, {"tag": "Ben"}, {"tag": ""}, {"tag": "Cy"}, {"tag": "Di"}]}
        """)
        let next = metadata(#"{"ratingKey": "12", "type": "episode", "title": "Gulls", "parentIndex": 2, "index": 5}"#)
        let details = TopShelfBuilder.Details(show: showDetails, next: next)

        #expect(TopShelfBuilder.genre(for: item, details: details) == "Drama")
        #expect(TopShelfBuilder.attributes(for: item, details: details) == [
            TopShelfAttribute(name: "Episode", values: ["S2 · E4 · Episode 4"]),
            TopShelfAttribute(name: "Next Episode", values: ["E5 · Gulls"]),
            TopShelfAttribute(name: "Starring", values: ["Ada", "Ben"]),
        ])
        let premiere = metadata(#"{"ratingKey": "13", "type": "episode", "title": "Return", "parentIndex": 3, "index": 1}"#)
        #expect(TopShelfBuilder.attributes(for: item, details: .init(next: premiere))[1] == TopShelfAttribute(name: "Next Episode", values: ["S3 · E1 · Return"]))

        let film = movie("21")
        let full = metadata(#"{"ratingKey": "21", "type": "movie", "title": "Movie 21", "Director": [{"tag": "Kay"}], "Role": [{"tag": "Lee"}]}"#)
        #expect(TopShelfBuilder.attributes(for: film, details: .init(item: full)) == [
            TopShelfAttribute(name: "Starring", values: ["Lee"]),
            TopShelfAttribute(name: "Director", values: ["Kay"]),
        ])
        let pair = metadata(#"{"ratingKey": "21", "type": "movie", "title": "Movie 21", "Director": [{"tag": "Kay"}, {"tag": "Mo"}, {"tag": "No"}]}"#)
        #expect(TopShelfBuilder.attributes(for: film, details: .init(item: pair)) == [TopShelfAttribute(name: "Directors", values: ["Kay", "Mo"])])
    }

    @Test func anEpisodeWithoutASynopsisBorrowsItsShows() {
        let item = episode("11", offset: 600_000)
        let showDetails = metadata(#"{"ratingKey": "100", "type": "show", "title": "The Show", "summary": "A coast."}"#)
        let snapshot = TopShelfBuilder.snapshot(
            picks: [.init(item: item, kind: .continueWatching)],
            details: ["11": .init(show: showDetails)],
            source: source,
            now: now
        )
        #expect(snapshot.sections[0].items[0].summary == "A coast.")
    }

    @Test func mediaBadgesComeFromTheStreams() {
        let full = metadata("""
        {"ratingKey": "21", "type": "movie", "title": "M", "Media": [{"width": 3840, "height": 1608, "videoResolution": "4k", "Part": [{"id": 1, "key": "/library/parts/1/file.mkv", "Stream": [
          {"streamType": 1, "displayTitle": "4K DoVi/HDR10 (HEVC Main 10)"},
          {"streamType": 2, "displayTitle": "English (TrueHD 7.1 Atmos)", "default": true},
          {"streamType": 2, "displayTitle": "English (AAC Stereo)", "title": "Audio Description"},
          {"streamType": 3, "displayTitle": "English SDH (SRT External)"},
          {"streamType": 3, "codec": "eia_608", "displayTitle": "English (EIA-608)"}
        ]}]}]}
        """)
        #expect(TopShelfBuilder.mediaOptions(for: full) == [.uhd, .dolbyVision, .atmos, .closedCaptions, .sdh, .audioDescription])

        let plain = metadata("""
        {"ratingKey": "22", "type": "movie", "title": "P", "Media": [{"width": 1920, "height": 800, "Part": [{"id": 2, "key": "/k", "Stream": [
          {"streamType": 1, "displayTitle": "1080p (H.264)"}, {"streamType": 2, "displayTitle": "English (AC3 5.1)"},
          {"streamType": 3, "displayTitle": "English (SRT)"}
        ]}]}]}
        """)
        #expect(TopShelfBuilder.mediaOptions(for: plain) == [.hd])
        #expect(TopShelfBuilder.mediaOptions(for: nil).isEmpty)
    }

    @Test func somethingUnderWayPreviewsTheSceneWhereTheViewerStopped() throws {
        let pick = TopShelfBuilder.Pick(item: movie("21", offset: 3_600_000), kind: .continueWatching)
        let preview = try #require(TopShelfBuilder.preview(for: pick, details: .init(), source: source))
        let url = preview.url
        #expect(url.path == "/video/:/transcode/universal/start.m3u8")
        let query = query(url)
        #expect(query["path"] == "/library/metadata/21")
        #expect(query["offset"] == "3590")
        #expect(query["protocol"] == "hls")
        #expect(query["directStream"] == "1")
        #expect(query["subtitles"] == "none")
        #expect(query["X-Plex-Token"] == "tok")
        #expect(query["X-Plex-Client-Identifier"] == "client-1")
        #expect(query["session"] == "topshelf-21")
        #expect(query["maxVideoBitrate"] == nil)
        #expect(preview.session == "topshelf-21")
    }

    @Test func aCappedQualityHoldsTheTranscodedPreviewToIt() throws {
        let capped = TopShelfBuilder.Source(serverURL: URL(string: "https://plex.example:32400")!, token: "tok", machineIdentifier: "m1", maxVideoBitrate: 8000)
        let pick = TopShelfBuilder.Pick(item: movie("21", offset: 5000), kind: .continueWatching)
        let preview = try #require(TopShelfBuilder.preview(for: pick, details: .init(), source: capped))
        #expect(query(preview.url)["maxVideoBitrate"] == "8000")
        #expect(query(preview.url)["offset"] == "0")
    }

    @Test func everythingElsePreviewsItsTrailerAsItIsWhenTheAppleTVCanPlayTheFile() throws {
        let full = metadata("""
        {"ratingKey": "21", "type": "movie", "title": "M", "Extras": {"Metadata": [
          {"ratingKey": "801", "type": "clip", "subtype": "behindTheScenes", "title": "Making of", "Media": [{"container": "mp4", "videoCodec": "h264", "audioCodec": "aac", "Part": [{"id": 9, "key": "/library/parts/9/file.mp4"}]}]},
          {"ratingKey": "802", "type": "clip", "subtype": "trailer", "title": "Trailer", "Media": [{"container": "mp4", "videoCodec": "h264", "audioCodec": "aac", "Part": [{"id": 10, "key": "/library/parts/10/1/file.mp4"}]}]}
        ]}}
        """)
        let preview = try #require(TopShelfBuilder.preview(for: .init(item: movie("21"), kind: .recentlyAdded), details: .init(item: full), source: source))
        #expect(preview.url.path == "/library/parts/10/1/file.mp4")
        #expect(query(preview.url)["X-Plex-Token"] == "tok")
        #expect(preview.session == nil)
    }

    @Test func aTrailerTheAppleTVCannotPlayGoesThroughTheTranscoderAndAnEpisodeUsesItsShows() throws {
        let showDetails = metadata("""
        {"ratingKey": "100", "type": "show", "title": "The Show", "Extras": {"Metadata": [
          {"ratingKey": "803", "type": "clip", "subtype": "trailer", "title": "Trailer", "Media": [{"container": "mkv", "videoCodec": "h264", "audioCodec": "dca", "Part": [{"id": 11, "key": "/library/parts/11/file.mkv"}]}]}
        ]}}
        """)
        let preview = try #require(TopShelfBuilder.preview(for: .init(item: episode("12"), kind: .upNext), details: .init(show: showDetails), source: source))
        #expect(preview.url.path == "/video/:/transcode/universal/start.m3u8")
        #expect(query(preview.url)["path"] == "/library/metadata/803")
        #expect(query(preview.url)["offset"] == nil)
        #expect(preview.session == "topshelf-803")

        #expect(TopShelfBuilder.preview(for: .init(item: episode("12"), kind: .upNext), details: .init(), source: source) == nil)
    }

    @Test func theNextEpisodeIsTheNextInTheSeasonOrTheFirstOfTheNextSeason() {
        let current = episode("11", index: 4)
        let season = [5, 3, 7, 4].map { metadata(#"{"ratingKey": "e\#($0)", "type": "episode", "title": "E\#($0)", "index": \#($0)}"#) }
        #expect(TopShelfBuilder.episode(after: current, in: season)?.id == "e5")
        #expect(TopShelfBuilder.episode(after: episode("17", index: 7), in: season) == nil)

        let seasons = [0, 1, 2, 4, 3].map { metadata(#"{"ratingKey": "s\#($0)", "type": "season", "title": "S\#($0)", "index": \#($0)}"#) }
        #expect(TopShelfBuilder.season(after: 2, in: seasons)?.id == "s3")
        #expect(TopShelfBuilder.season(after: 4, in: seasons) == nil)
    }

    @Test func theSnapshotCarriesEverythingThePlanHandsTheCarousel() throws {
        let full = metadata("""
        {"ratingKey": "21", "type": "movie", "title": "M", "Genre": [{"tag": "Thriller"}], "Role": [{"tag": "Lee"}],
         "Media": [{"width": 1920, "height": 1080, "Part": [{"id": 1, "key": "/k", "Stream": [{"streamType": 1, "displayTitle": "1080p"}]}]}]}
        """)
        let snapshot = TopShelfBuilder.snapshot(
            picks: [.init(item: movie("21", offset: 3_600_000), kind: .continueWatching)],
            details: ["21": .init(item: full)],
            source: source,
            now: now
        )
        let decoded = try JSONDecoder().decode(TopShelfSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        let plan = try #require(TopShelfPlan(snapshot: snapshot, now: now, calendar: calendar))
        let card = plan.items[0]
        #expect(card.title == "Movie 21")
        #expect(card.contextTitle == "Continue Watching · 1 h 00 m left")
        #expect(card.genre == "Thriller")
        #expect(card.duration == 7200)
        #expect(card.creationDate.map { calendar.component(.year, from: $0) } == 2021)
        #expect(card.mediaOptions == [.hd])
        #expect(card.attributes == [TopShelfAttribute(name: "Starring", values: ["Lee"])])
        #expect(card.previewURL?.path == "/video/:/transcode/universal/start.m3u8")
        #expect(snapshot.sections[0].items[0].previewSession == "topshelf-21")
    }

    @Test func theLastVersionsSnapshotStaysOnScreenUntilTheAppWritesTheNewOne() throws {
        let legacy = #"{"schema": 2, "machineIdentifier": "m1", "savedAt": 0, "sections": [{"title": "Continue Watching", "items": [{"ratingKey": "1", "type": "episode", "title": "Low Tide", "subtitle": "The Show · S2 · E4", "progress": 0.5}]}]}"#
        let old = try JSONDecoder().decode(TopShelfSnapshot.self, from: Data(legacy.utf8))
        let card = try #require(TopShelfPlan(snapshot: old)?.items.first)
        #expect(card.title == "Low Tide")
        #expect(card.contextTitle == "The Show · S2 · E4")
        #expect(card.previewURL == nil)
        #expect(card.mediaOptions.isEmpty)

        let older = TopShelfSnapshot(schema: 1, machineIdentifier: "m1", savedAt: 0, sections: old.sections)
        #expect(TopShelfPlan(snapshot: older) == nil)
    }
}
