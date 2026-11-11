import Foundation
import Testing
@testable import CrucibleCore

struct CollectionsAndPlaylistsTests {
    private let base = URL(string: "http://192.168.1.5:32400")!
    private let server = DetailStubServer()

    private func request(_ endpoint: PlexEndpoint) throws -> URLRequest {
        try endpoint.urlRequest(baseURL: base, token: "tok")
    }

    private func decode(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private func entry(_ key: String, _ title: String, itemID: Int? = nil) -> [String: Any] {
        var fields: [String: Any] = ["ratingKey": key, "title": title, "type": "movie"]
        if let itemID { fields["playlistItemID"] = itemID }
        return fields
    }

    @Test func collectionEndpointsPageTheListing() throws {
        let list = try request(.sectionCollections(sectionId: "3", start: 200, size: 100))
        #expect(list.url?.path == "/library/sections/3/collections")
        #expect(list.url?.query == "X-Plex-Container-Start=200&X-Plex-Container-Size=100")
        #expect(list.httpMethod == "GET")
        let items = try request(.collectionItems(ratingKey: "88"))
        #expect(items.url?.path == "/library/collections/88/children")
    }

    @Test func playlistEndpointsUseTheRightVerbsAndPaths() throws {
        let list = try request(.playlists)
        #expect(list.url?.absoluteString == "http://192.168.1.5:32400/playlists?playlistType=video")

        let create = try request(.createPlaylist(title: "Date Night", uri: "server://m/com.plexapp.plugins.library/library/metadata/1,2"))
        #expect(create.httpMethod == "POST")
        #expect(create.url?.path == "/playlists")
        #expect(create.url?.query == "type=video&title=Date%20Night&smart=0&uri=server://m/com.plexapp.plugins.library/library/metadata/1,2")

        let add = try request(.addToPlaylist(ratingKey: "9", uri: "server://m/com.plexapp.plugins.library/library/metadata/4"))
        #expect(add.httpMethod == "PUT")
        #expect(add.url?.path == "/playlists/9/items")

        let remove = try request(.removeFromPlaylist(ratingKey: "9", playlistItemID: 31))
        #expect(remove.httpMethod == "DELETE")
        #expect(remove.url?.path == "/playlists/9/items/31")

        let move = try request(.movePlaylistItem(ratingKey: "9", playlistItemID: 31, after: 28))
        #expect(move.httpMethod == "PUT")
        #expect(move.url?.path == "/playlists/9/items/31/move")
        #expect(move.url?.query == "after=28")
        #expect(try request(.movePlaylistItem(ratingKey: "9", playlistItemID: 31, after: nil)).url?.query == nil)

        let delete = try request(.deletePlaylist(ratingKey: "9"))
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path == "/playlists/9")
    }

    @Test func aPlaylistDecodesItsKindAndPictureAndEntries() throws {
        let playlist = try decode(#"{"ratingKey":"9","type":"playlist","title":"Friday","smart":true,"composite":"/playlists/9/composite/17","leafCount":4}"#)
        #expect(playlist.mediaType == "playlist")
        #expect(playlist.isSmart)
        #expect(playlist.composite == "/playlists/9/composite/17")

        let manual = try decode(#"{"ratingKey":"10","type":"playlist","title":"Mine","smart":0}"#)
        #expect(!manual.isSmart)
        let numeric = try decode(#"{"ratingKey":"11","type":"playlist","title":"Rules","smart":"1"}"#)
        #expect(numeric.isSmart)

        let entry = try decode(#"{"ratingKey":"5","type":"movie","title":"Halcyon","playlistItemID":"77"}"#)
        #expect(entry.playlistItemID == 77)
    }

    @Test func aTitleListsTheCollectionsItBelongsTo() throws {
        let movie = try decode(#"{"ratingKey":"1","type":"movie","title":"Halcyon","Collection":[{"tag":"Salvage Stories"},{"tag":"Night Shift"}]}"#)
        #expect(movie.collectionNames == ["Salvage Stories", "Night Shift"])
        #expect(try decode(#"{"ratingKey":"2","type":"movie","title":"Alone"}"#).collectionNames.isEmpty)
    }

    @Test func itemURIsNameTheServerAndEveryKey() {
        #expect(PlexItemURI.make(machineIdentifier: "abc", ratingKeys: ["1", "22"]) == "server://abc/com.plexapp.plugins.library/library/metadata/1,22")
    }

    @Test func aCollectionListingIsReadToTheEnd() async throws {
        server.reply(path: "/library/sections/3/collections", body: [
            "MediaContainer": ["size": 1, "totalSize": 1, "Metadata": [entry("88", "Salvage Stories")]],
        ])
        let found = try await CollectionsFeed.collections(inSection: "3", api: server.client)
        #expect(found.map(\.id) == ["88"])
    }

    @Test func aTagFindsItsCollectionByNameWhateverTheCase() async throws {
        server.reply(path: "/library/sections/3/collections", body: [
            "MediaContainer": ["size": 2, "Metadata": [entry("88", "Salvage Stories"), entry("89", "Night Shift")]],
        ])
        let match = try await CollectionsFeed.collection(named: " night shift ", inSection: "3", api: server.client)
        #expect(match?.id == "89")
        #expect(try await CollectionsFeed.collection(named: "Missing", inSection: "3", api: server.client) == nil)
    }

    @Test func aCollectionsTitlesComeFromItsChildren() async throws {
        server.reply(path: "/library/collections/88/children", body: [
            "MediaContainer": ["size": 2, "Metadata": [entry("1", "Halcyon"), entry("2", "Deep Field")]],
        ])
        let items = try await CollectionsFeed.items(inCollection: "88", api: server.client)
        #expect(items.map(\.title) == ["Halcyon", "Deep Field"])
    }

    @Test func countTextReadsTheChildCount() throws {
        #expect(CollectionFormat.countText(try decode(#"{"ratingKey":"1","type":"collection","title":"A","childCount":12}"#)) == "12 titles")
        #expect(CollectionFormat.countText(try decode(#"{"ratingKey":"1","type":"collection","title":"A","childCount":1}"#)) == "1 title")
        #expect(CollectionFormat.countText(try decode(#"{"ratingKey":"1","type":"collection","title":"A"}"#)) == nil)
    }

    @Test func onlyPlaylistsAreListed() async throws {
        var playlist = entry("9", "Friday")
        playlist["type"] = "playlist"
        server.reply(path: "/playlists", body: ["MediaContainer": ["size": 2, "Metadata": [playlist, entry("5", "Stray")]]])
        let lists = try await PlaylistsFeed.playlists(api: server.client)
        #expect(lists.map(\.id) == ["9"])
    }

    @Test func smartPlaylistsAreNotOfferedForAdding() throws {
        let smart = try decode(#"{"ratingKey":"1","type":"playlist","title":"Rules","smart":true}"#)
        let manual = try decode(#"{"ratingKey":"2","type":"playlist","title":"Mine","smart":false}"#)
        #expect(PlaylistService.editable([smart, manual]).map(\.id) == ["2"])
    }

    @Test func creatingAPlaylistSendsTheTitleAndTheServersAddressOfTheItems() async throws {
        var created = entry("9", "Date Night")
        created["type"] = "playlist"
        server.reply(path: "/playlists", body: ["MediaContainer": ["size": 1, "Metadata": [created]]])
        let made = try await PlaylistService.create(title: "  Date Night ", adding: ["1", "2"], machineIdentifier: "machine", api: server.client)
        #expect(made?.id == "9")
        let sent = try #require(server.requestedURLs.last)
        #expect(sent.contains("title=Date%20Night"))
        #expect(sent.contains("uri=server://machine/com.plexapp.plugins.library/library/metadata/1,2"))
    }

    @Test func aPlaylistWithoutANameOrTitlesIsNotCreated() async throws {
        #expect(try await PlaylistService.create(title: "   ", adding: ["1"], machineIdentifier: "m", api: server.client) == nil)
        #expect(try await PlaylistService.create(title: "Named", adding: [], machineIdentifier: "m", api: server.client) == nil)
        #expect(server.requests.isEmpty)
    }

    @Test func addingSendsTheKeysToThePlaylist() async throws {
        server.reply(path: "/playlists/9/items")
        try await PlaylistService.add(["4", "5"], toPlaylist: "9", machineIdentifier: "machine", api: server.client)
        #expect(server.requestedURLs.last?.hasSuffix("uri=server://machine/com.plexapp.plugins.library/library/metadata/4,5") == true)
    }

    @Test func aRefusedEditIsAFailure() async {
        server.reply(path: "/playlists/9/items/31", status: 404)
        await #expect(throws: APIError.self) {
            try await PlaylistService.remove(playlistItemID: 31, fromPlaylist: "9", api: server.client)
        }
    }

    @Test func movingNamesTheEntryItNowFollows() throws {
        let entries = [("a", 11), ("b", 12), ("c", 13), ("d", 14)].map { key, id in
            try! decode(#"{"ratingKey":"\#(key)","type":"movie","title":"\#(key)","playlistItemID":\#(id)}"#)
        }
        #expect(PlaylistService.anchor(movingFrom: 3, to: 1, in: entries) == 11)
        #expect(PlaylistService.anchor(movingFrom: 0, to: 2, in: entries) == 13)
        #expect(PlaylistService.anchor(movingFrom: 2, to: 0, in: entries) == nil)
        #expect(PlaylistService.anchor(movingFrom: 1, to: 1, in: entries) == nil)
        #expect(PlaylistService.anchor(movingFrom: 9, to: 0, in: entries) == nil)
    }
}

struct PersonFilmographyTests {
    private let server = DetailStubServer()

    private func movie(_ key: String, _ title: String, year: Int) -> [String: Any] {
        ["ratingKey": key, "title": title, "type": "movie", "year": year]
    }

    @Test func theActorFilterRidesTheSectionListing() throws {
        let request = try PlexEndpoint.sectionItems(sectionId: "3", size: 200, actor: "63173").urlRequest(baseURL: URL(string: "http://h:32400")!, token: "t")
        #expect(request.url?.query == "X-Plex-Container-Start=0&X-Plex-Container-Size=200&actor=63173")
    }

    @Test func aPersonsTitlesAreGatheredFromEveryLibraryNewestFirst() async throws {
        server.reply(path: "/library/sections", body: ["MediaContainer": ["Directory": [
            ["key": "1", "type": "movie", "title": "Movies"],
            ["key": "2", "type": "show", "title": "Shows"],
            ["key": "4", "type": "artist", "title": "Music"],
        ]]])
        server.reply(path: "/library/sections/1/all", body: ["MediaContainer": ["size": 2, "Metadata": [movie("1", "Halcyon", year: 2021), movie("2", "Deep Field", year: 2026)]]])
        server.reply(path: "/library/sections/2/all", body: ["MediaContainer": ["size": 1, "Metadata": [["ratingKey": "9", "title": "The Salt Road", "type": "show", "year": 2023]]]])
        let person = PlexRole(id: 63173, tag: "Maren Vale", role: "Pilot", thumb: nil)
        let titles = try await PersonFilmography.titles(of: person, api: server.client)
        #expect(titles.map(\.title) == ["Deep Field", "The Salt Road", "Halcyon"])
        #expect(server.requestedURLs.filter { $0.contains("actor=63173") }.count == 2)
        #expect(!server.requests.contains("/library/sections/4/all"))
    }

    @Test func crewWithoutAnIdHaveNoFilmography() async throws {
        let crew = PlexRole(id: nil, tag: "Ana Reyes", role: "Director", thumb: nil)
        #expect(!PersonFilmography.canOpen(crew))
        #expect(try await PersonFilmography.titles(of: crew, api: server.client).isEmpty)
        #expect(server.requests.isEmpty)
    }
}

struct ServerActivityTests {
    private let server = DetailStubServer()

    private func session(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    @Test func aSessionNamesWhoIsWatchingOnWhatAndHow() throws {
        let transcoding = try session(#"""
        {"ratingKey":"1","type":"movie","title":"Halcyon","User":{"id":"2","title":"Maren"},
         "Player":{"title":"Living Room Apple TV","product":"Plex for Apple TV","state":"playing"},
         "TranscodeSession":{"videoDecision":"transcode","audioDecision":"copy"}}
        """#)
        #expect(ServerActivity.subtitle(transcoding) == "Maren · Playing, Transcoding · Living Room Apple TV")
        #expect(ServerActivity.isTranscoding(transcoding))

        let direct = try session(#"""
        {"ratingKey":"2","type":"episode","title":"Low Tide","User":{"title":"Idris"},
         "Player":{"product":"Plex Web","state":"paused"},"TranscodeSession":{"videoDecision":"copy","audioDecision":"copy"}}
        """#)
        #expect(ServerActivity.subtitle(direct) == "Idris · Paused · Plex Web")
        #expect(!ServerActivity.isTranscoding(direct))
    }

    @Test func aSessionWithNoDetailsHasNoSubtitle() throws {
        #expect(ServerActivity.subtitle(try session(#"{"ratingKey":"3","type":"movie","title":"Bare"}"#)) == nil)
    }

    @Test func theServerListsItsSessions() async throws {
        server.reply(path: "/status/sessions", body: ["MediaContainer": ["size": 2, "Metadata": [
            ["ratingKey": "1", "title": "Halcyon", "type": "movie", "User": ["title": "Maren"]],
            ["ratingKey": "2", "title": "Low Tide", "type": "movie"],
        ]]])
        let sessions = try await ServerActivity.sessions(api: server.client)
        #expect(sessions.map(\.title) == ["Halcyon", "Low Tide"])
        #expect(sessions.first?.sessionUser?.title == "Maren")
    }
}

struct DetailExtrasTests {
    private func extra(_ key: String, _ title: String, subtype: String, playable: Bool = true) -> [String: Any] {
        var fields: [String: Any] = ["ratingKey": key, "type": "clip", "subtype": subtype, "title": title, "duration": 135_000]
        if playable { fields["Media"] = [["id": 1, "Part": [["id": 2, "key": "/library/parts/2/1/file.mp4"]]]] }
        return fields
    }

    private func movie(extras: [[String: Any]]) -> PlexMetadata {
        DetailFixtures.item(["Extras": ["size": extras.count, "Metadata": extras]])
    }

    @Test func extrasDecodeWithTheirKind() {
        let item = movie(extras: [extra("10", "Official Trailer", subtype: "trailer")])
        #expect(item.extras.map(\.title) == ["Official Trailer"])
        #expect(item.extras.first?.subtype == "trailer")
        #expect(DetailFixtures.item().extras.isEmpty)
    }

    @Test func trailersComeFirstAndClipsWithNothingToPlayAreLeftOut() {
        let item = movie(extras: [
            extra("11", "Making Of", subtype: "behindTheScenes"),
            extra("12", "Cut Scene", subtype: "deletedScene", playable: false),
            extra("13", "Teaser", subtype: "trailer"),
            extra("14", "Cast Talk", subtype: "interview"),
        ])
        #expect(DetailExtras.items(in: item).map(\.title) == ["Teaser", "Making Of", "Cast Talk"])
    }

    @Test func aClipIsDescribedByItsKindAndLength() throws {
        let item = movie(extras: [extra("10", "Official Trailer", subtype: "trailer"), extra("11", "Unknown", subtype: "mystery")])
        #expect(DetailExtras.subtitle(item.extras[0]) == "Trailer · 2 min")
        #expect(DetailExtras.kindName(item.extras[1]) == "Extra")
    }

    @Test func playingAnExtraNamesTheTitleAndLeavesNoTrace() {
        let item = DetailFixtures.item(["ratingKey": "1", "title": "Halcyon", "thumb": "/poster"])
        let clip = DetailFixtures.item(["ratingKey": "10", "type": "clip", "title": "Official Trailer", "duration": 135_000])
        let request = PlaybackRequest.extra(clip, of: item)
        #expect(request.isExtra)
        #expect(request.ratingKey == "10")
        #expect(request.mediaType == "clip")
        #expect(request.resumePosition == 0)
        #expect(request.metadata?.showName == "Halcyon")
        #expect(request.metadata?.posterPath == "/poster")
        #expect(!PlaybackRequest(item: item).isExtra)
    }

    @Test func aMovieNeverAsksForANextEpisodeAfterAClip() {
        let resolver = UpNextResolver(ratingKey: "10", isEpisode: false, seasonRatingKey: nil, markers: [])
        #expect(!resolver.canOfferNext)
    }
}

struct LibraryFacetTests {
    @Test func theFilterRidesTheListingUnderTheServersName() throws {
        let endpoint = PlexEndpoint.sectionItems(sectionId: "1", size: 50, filters: ["resolution": "4k", "decade": "2020"])
        let request = try endpoint.urlRequest(baseURL: URL(string: "http://h:32400")!, token: "t")
        #expect(request.url?.query == "X-Plex-Container-Start=0&X-Plex-Container-Size=50&decade=2020&resolution=4k")
        let list = try PlexEndpoint.sectionFacet(sectionId: "1", facet: LibraryFacet.contentRating.queryName).urlRequest(baseURL: URL(string: "http://h:32400")!, token: "t")
        #expect(list.url?.path == "/library/sections/1/contentRating")
    }

    @Test func optionsKeepFacetsAndClearThemWithEveryFilter() {
        var options = LibraryGridOptions()
        #expect(!options.isFiltering)
        options.facets[.decade] = "2010"
        options.facets[.resolution] = "1080"
        #expect(options.isFiltering)
        #expect(options.endpoint(sectionId: "1", start: 0, size: 50).queryItems?.map(\.name).suffix(2) == ["decade", "resolution"])
        #expect(options.selectingChip(.all).facets.isEmpty)
        #expect(options.clearingFilters().facets.isEmpty)
        #expect(!options.clearingFilters().isFiltering)
    }

    @Test func aFacetButtonShowsTheChosenValue() {
        var options = LibraryGridOptions()
        let choices = [LibraryFacetChoice(key: "4k", title: "4k"), LibraryFacetChoice(key: "1080", title: "1080")]
        #expect(options.facetTitle(.resolution, in: choices) == "Resolution")
        options.facets[.resolution] = "1080"
        #expect(options.facetTitle(.resolution, in: choices) == "1080p")
        options.facets[.resolution] = "4k"
        #expect(options.facetTitle(.resolution, in: choices) == "4K")
        options.facets[.resolution] = "gone"
        #expect(options.facetTitle(.resolution, in: choices) == "Resolution")
    }

    @Test func resolutionsReadLikeTheBadges() {
        #expect(LibraryFacet.resolution.display("sd") == "SD")
        #expect(LibraryFacet.resolution.display("720") == "720p")
        #expect(LibraryFacet.decade.display("2020s") == "2020s")
    }
}

struct SubtitleSearchTests {
    private let server = DetailStubServer()

    @Test func theSearchAndTheDownloadUseTheSubtitlesPath() throws {
        let base = URL(string: "http://h:32400")!
        let search = try PlexEndpoint.searchSubtitles(ratingKey: "42", language: "fi", hearingImpaired: true, forced: false).urlRequest(baseURL: base, token: "t")
        #expect(search.httpMethod == "GET")
        #expect(search.url?.path == "/library/metadata/42/subtitles")
        #expect(search.url?.query == "language=fi&hearingImpaired=1&forced=0")
        let candidate = PlexSubtitleCandidate(key: "/k/1", codec: "srt", format: "srt", languageCode: "fi", providerTitle: "OpenSubtitles", hearingImpaired: true)
        let query = SubtitleSearch.downloadQuery(for: candidate, language: "fi")
        let download = try PlexEndpoint.downloadSubtitle(ratingKey: "42", query: query).urlRequest(baseURL: base, token: "t")
        #expect(download.httpMethod == "PUT")
        #expect(download.url?.path == "/library/metadata/42/subtitles")
        #expect(download.url?.query == "key=/k/1&codec=srt&format=srt&forced=0&hearingImpaired=1&language=fi&providerTitle=OpenSubtitles")
    }

    @Test func candidatesDecodeLeniently() throws {
        let json = #"{"MediaContainer":{"Stream":[{"key":"/k/1","codec":"srt","languageCode":"eng","providerTitle":"OpenSubtitles","score":"87.5","hearingImpaired":"1","perfectMatch":true},{"key":"/k/2","format":"ass","score":12}]}}"#
        let response = try JSONDecoder().decode(PlexSubtitleSearchResponse.self, from: Data(json.utf8))
        let found = try #require(response.MediaContainer.Stream)
        #expect(found.map(\.key) == ["/k/1", "/k/2"])
        #expect(found[0].score == 87.5)
        #expect(found[0].hearingImpaired)
        #expect(found[0].perfectMatch)
        #expect(!found[1].hearingImpaired)
        #expect(found[1].format == "ass")
    }

    @Test func theBestMatchesComeFirst() async throws {
        server.reply(path: "/library/metadata/42/subtitles", body: ["MediaContainer": ["Stream": [
            ["key": "/k/a", "score": 40],
            ["key": "/k/b", "score": 90],
            ["key": "/k/c", "score": 10, "perfectMatch": true],
        ]]])
        let found = try await SubtitleSearch.search(ratingKey: "42", language: "en", api: server.client)
        #expect(found.map(\.key) == ["/k/c", "/k/b", "/k/a"])
        #expect(server.requestedURLs.last?.contains("language=en") == true)
    }

    @Test func downloadingSendsTheChoiceAndDropsTheCachedTitle() async throws {
        let api = server.client
        server.reply(path: "/library/metadata/42", items: [DetailFixtures.item(["ratingKey": "42"])])
        server.reply(path: "/library/metadata/42/subtitles")
        _ = try await api.requestContainer(.metadata(ratingKey: "42"))
        try await SubtitleSearch.download(PlexSubtitleCandidate(key: "/k/a", languageCode: "en"), ratingKey: "42", language: "en", api: api)
        #expect(server.requestedURLs.last?.contains("key=/k/a") == true)
        _ = try await api.requestContainer(.metadata(ratingKey: "42"))
        #expect(server.requests.filter { $0 == "/library/metadata/42" }.count == 2)
    }

    @Test func aRefusedDownloadIsAFailure() async {
        server.reply(path: "/library/metadata/42/subtitles", status: 500)
        await #expect(throws: APIError.self) {
            try await SubtitleSearch.download(PlexSubtitleCandidate(key: "/k/a"), ratingKey: "42", language: "en", api: server.client)
        }
    }

    @Test func aCandidateIsDescribedByWhatMatters() {
        let plain = PlexSubtitleCandidate(key: "/k/1", providerTitle: "OpenSubtitles")
        #expect(SubtitleSearch.detail(plain) == "OpenSubtitles")
        let rich = PlexSubtitleCandidate(key: "/k/2", providerTitle: "OpenSubtitles", hearingImpaired: true, perfectMatch: true)
        #expect(SubtitleSearch.detail(rich) == "OpenSubtitles · Perfect match · SDH")
    }

    @Test func theDefaultLanguageFollowsThePreferencesWhenListed() {
        #expect(SubtitleLanguages.defaultCode(preferred: ["fi-FI", "en-US"]) == "fi")
        #expect(SubtitleLanguages.defaultCode(preferred: ["xx-XX", "de-DE"]) == "de")
        #expect(SubtitleLanguages.defaultCode(preferred: ["xx"]) == "en")
        #expect(SubtitleLanguages.defaultCode(preferred: ["nb-NO", "en-US"]) == "no")
        #expect(SubtitleLanguages.defaultCode(preferred: ["is-IS"]) == "is")
        #expect(SubtitleLanguages.defaultCode(preferred: ["sv-SE"]) == "sv")
        #expect(SubtitleLanguages.defaultCode(preferred: ["da-DK"]) == "da")
        #expect(SubtitleLanguages.defaultCode(preferred: []) == "en")
    }
}

struct WatchlistTests {
    private let server = DetailStubServer()

    @Test func theKeyPlexTVKnowsATitleByIsTheEndOfItsGuid() {
        #expect(WatchlistService.discoverKey(fromGuid: "plex://movie/5d776b59ad5437001f79c6f8") == "5d776b59ad5437001f79c6f8")
        #expect(WatchlistService.discoverKey(fromGuid: "tt0111161") == nil)
        #expect(WatchlistService.discoverKey(fromGuid: "plex://") == nil)
    }

    @Test func watchlistRequestsUseThePlexTVPathsAndVerbs() throws {
        let list = try PlexEndpoint.watchlist(start: 100, size: 50).urlRequest(baseURL: URL(string: "http://pms:32400")!, token: "t")
        #expect(list.url?.path == "/library/sections/watchlist/all")
        #expect(list.url?.query == "X-Plex-Container-Start=100&X-Plex-Container-Size=50")
        #expect(list.url?.host != "pms")
        let add = try PlexEndpoint.addToWatchlist(guid: "plex://movie/abc123").urlRequest(baseURL: URL(string: "http://pms:32400")!, token: "t")
        #expect(add.httpMethod == "PUT")
        #expect(add.url?.path == "/actions/addToWatchlist")
        #expect(add.url?.query == "ratingKey=abc123")
        let remove = try PlexEndpoint.removeFromWatchlist(guid: "plex://show/def").urlRequest(baseURL: URL(string: "http://pms:32400")!, token: "t")
        #expect(remove.url?.path == "/actions/removeFromWatchlist")
        #expect(remove.url?.query == "ratingKey=def")
    }

    @Test func aTitleIsOnTheWatchlistWhenItsGuidIs() throws {
        let listed = DetailFixtures.item(["guid": "plex://movie/1", "title": "A"])
        #expect(listed.guid == "plex://movie/1")
        #expect(WatchlistService.contains(guid: "plex://movie/1", in: [listed]))
        #expect(!WatchlistService.contains(guid: "plex://movie/2", in: [listed]))
        #expect(!WatchlistService.contains(guid: nil, in: [listed]))
    }

    @Test func aWatchlistEntryFindsItsTitleOnTheServerByGuid() async throws {
        server.reply(path: "/hubs/search", body: ["MediaContainer": ["Hub": [["type": "movie", "Metadata": [
            ["ratingKey": "5", "type": "movie", "title": "Halcyon Bay", "guid": "plex://movie/other", "year": 2015],
            ["ratingKey": "6", "type": "movie", "title": "Halcyon", "guid": "plex://movie/abc", "year": 2021],
        ]]]]])
        let entry = DetailFixtures.item(["ratingKey": "abc", "type": "movie", "title": "Halcyon", "guid": "plex://movie/abc", "year": 2021])
        #expect(try await WatchlistService.localMatch(for: entry, api: server.client)?.id == "6")
        let missing = DetailFixtures.item(["ratingKey": "zzz", "type": "movie", "title": "Halcyon", "guid": "plex://movie/zzz", "year": 1999])
        #expect(try await WatchlistService.localMatch(for: missing, api: server.client) == nil)
    }
}
