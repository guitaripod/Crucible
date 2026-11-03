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
