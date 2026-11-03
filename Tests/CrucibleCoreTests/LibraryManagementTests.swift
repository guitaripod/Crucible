import Foundation
import Testing
@testable import CrucibleCore

struct OwnerEndpointTests {
    private let server = URL(string: "http://192.168.1.5:32400")!

    private func request(_ endpoint: PlexEndpoint) throws -> URLRequest {
        try endpoint.urlRequest(baseURL: server, token: "tok")
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    @Test func scanIsAGetAndForceAddsTheFlag() throws {
        let plain = try request(.scanSection(sectionId: "3", force: false))
        #expect(plain.url?.absoluteString == "http://192.168.1.5:32400/library/sections/3/refresh")
        #expect(plain.httpMethod == "GET")
        let forced = try request(.scanSection(sectionId: "3", force: true))
        #expect(forced.url?.absoluteString == "http://192.168.1.5:32400/library/sections/3/refresh?force=1")
    }

    @Test func libraryAndTitleToolsArePuts() throws {
        let puts: [PlexEndpoint] = [
            .analyzeSection(sectionId: "3"), .emptyTrash(sectionId: "3"), .refreshItem(ratingKey: "9"), .analyzeItem(ratingKey: "9"),
            .unmatch(ratingKey: "9"), .updaterCheck, .updaterApply,
        ]
        for endpoint in puts {
            #expect(try request(endpoint).httpMethod == "PUT", "\(endpoint.path)")
        }
        #expect(try request(.emptyTrash(sectionId: "3")).url?.path == "/library/sections/3/emptyTrash")
        #expect(try request(.analyzeItem(ratingKey: "9")).url?.path == "/library/metadata/9/analyze")
    }

    @Test func deletingATitleOrATaskIsADelete() throws {
        let item = try request(.deleteItem(ratingKey: "9"))
        #expect(item.httpMethod == "DELETE")
        #expect(item.url?.path == "/library/metadata/9")
        let task = try request(.cancelActivity(uuid: "abc-123"))
        #expect(task.httpMethod == "DELETE")
        #expect(task.url?.path == "/activities/abc-123")
        let history = try request(.deleteHistoryEntry(historyId: "77"))
        #expect(history.httpMethod == "DELETE")
        #expect(history.url?.path == "/status/sessions/history/77")
    }

    @Test func fixMatchSearchesManuallyWithTheTitleAndYear() throws {
        let search = try request(.matches(ratingKey: "9", title: "Dune", year: 2021))
        #expect(search.httpMethod == "GET")
        #expect(search.url?.path == "/library/metadata/9/matches")
        #expect(query(search) == ["manual": "1", "title": "Dune", "year": "2021"])
        #expect(query(try request(.matches(ratingKey: "9", title: "", year: nil))) == ["manual": "1"])
    }

    @Test func matchingSendsTheGuidNameAndYear() throws {
        let match = try request(.match(ratingKey: "9", guid: "plex://movie/5d77", name: "Dune", year: 2021))
        #expect(match.httpMethod == "PUT")
        #expect(match.url?.path == "/library/metadata/9/match")
        #expect(query(match) == ["guid": "plex://movie/5d77", "name": "Dune", "year": "2021"])
    }

    @Test func editingLocksEveryFieldItSends() throws {
        let edit = try request(.editFields(sectionId: "1", ratingKey: "9", type: 1, values: ["title": "Dune", "summary": "Sand."]))
        #expect(edit.httpMethod == "PUT")
        #expect(edit.url?.path == "/library/sections/1/all")
        #expect(query(edit) == ["type": "1", "id": "9", "title.value": "Dune", "title.locked": "1", "summary.value": "Sand.", "summary.locked": "1"])
    }

    @Test func artworkListsAndSelectionsUseTheKindsPaths() throws {
        #expect(try request(.artwork(ratingKey: "9", kind: .poster)).url?.path == "/library/metadata/9/posters")
        #expect(try request(.artwork(ratingKey: "9", kind: .background)).url?.path == "/library/metadata/9/arts")
        let select = try request(.selectArtwork(ratingKey: "9", kind: .background, url: "upload://art/abc"))
        #expect(select.httpMethod == "PUT")
        #expect(select.url?.path == "/library/metadata/9/art")
        #expect(query(select) == ["url": "upload://art/abc"])
    }

    @Test func stoppingAStreamNamesTheSessionAndTheReason() throws {
        let stop = try request(.terminateSession(sessionId: "s-1", reason: "Closing time"))
        #expect(stop.httpMethod == "GET")
        #expect(stop.url?.path == "/status/sessions/terminate")
        #expect(query(stop) == ["sessionId": "s-1", "reason": "Closing time"])
    }

    @Test func dashboardReadsTheUpdaterAndTheLastMinutesOfLoad() throws {
        #expect(query(try request(.updaterCheck)) == ["download": "0"])
        #expect(query(try request(.updaterApply)) == ["tonight": "0", "skip": "0"])
        let load = try request(.resourceStatistics)
        #expect(load.url?.path == "/statistics/resources")
        #expect(query(load) == ["timespan": "6"])
        #expect(try request(.updaterStatus).httpMethod == "GET")
        #expect(try request(.activities).url?.path == "/activities")
    }
}

struct LibraryManagementTests {
    @Test func fixMatchListsTheSurestCandidatesFirst() async throws {
        let stub = DetailStubServer()
        stub.reply(path: "/library/metadata/9/matches", body: ["MediaContainer": ["size": 3, "SearchResult": [
            ["guid": "plex://movie/b", "name": "Dune", "year": "1984", "score": "61"],
            ["guid": "plex://movie/a", "name": "Dune", "year": 2021, "score": 98, "matched": true],
            ["guid": "plex://movie/c", "name": "Dune Drifter"],
        ]]])
        let results = try await LibraryManagement.matches(ratingKey: "9", title: "Dune", year: nil, api: stub.client)
        #expect(results.map(\.guid) == ["plex://movie/a", "plex://movie/b", "plex://movie/c"])
        #expect(results[1].year == 1984)
        #expect(results[1].score == 61)
        #expect(results[0].matched == true)
    }

    @Test func choosingArtworkSendsTheChoicesKeyAsTheURL() async throws {
        let stub = DetailStubServer()
        stub.reply(path: "/library/metadata/9/posters", body: ["MediaContainer": ["size": 2, "Metadata": [
            ["key": "https://images.example/p1.jpg", "ratingKey": "https://images.example/p1.jpg", "thumb": "/library/metadata/9/file?url=p1", "selected": true, "provider": "tmdb"],
            ["key": "upload://posters/abc", "ratingKey": "upload://posters/abc"],
        ]]])
        stub.reply(path: "/library/metadata/9/poster", body: [:])
        let choices = try await LibraryManagement.artwork(ratingKey: "9", kind: .poster, api: stub.client)
        #expect(choices.count == 2)
        #expect(choices[0].imagePath == "/library/metadata/9/file?url=p1")
        #expect(choices[1].imagePath == "upload://posters/abc")
        try await LibraryManagement.select(choices[1], kind: .poster, ratingKey: "9", api: stub.client)
        #expect(stub.requestedURLs.last?.hasSuffix("/library/metadata/9/poster?url=upload://posters/abc") == true)
    }

    @Test func refusedToolsThrowSoTheViewerHearsTheServerSaidNo() async {
        let stub = DetailStubServer()
        stub.reply(path: "/library/metadata/9", status: 403, body: ["errors": [["code": 1, "message": "Media deletion is not allowed"]]])
        await #expect(throws: (any Error).self) {
            try await LibraryManagement.delete(ratingKey: "9", api: stub.client)
        }
    }

    @Test func anUpdateIsOfferedOnlyWhenOneIsWaiting() async throws {
        let stub = DetailStubServer()
        stub.reply(path: "/updater/status", body: ["MediaContainer": ["size": 2, "Release": [
            ["version": "1.41.0", "state": "installed"],
            ["version": "1.43.6", "state": "notify", "added": "Faster scans.", "fixed": "Subtitle timing."],
        ]]])
        let release = try await LibraryManagement.availableUpdate(api: stub.client)
        #expect(release?.version == "1.43.6")
        #expect(release?.added == "Faster scans.")
        stub.reply(path: "/updater/status", body: ["MediaContainer": ["size": 1, "Release": [["version": "1.41.0", "state": "installed"]]]])
        let upToDate = try await LibraryManagement.availableUpdate(api: stub.client)
        #expect(upToDate == nil)
        stub.reply(path: "/updater/status", body: ["MediaContainer": ["size": 0]])
        let noReleases = try await LibraryManagement.availableUpdate(api: stub.client)
        #expect(noReleases == nil)
    }

    @Test func theDashboardShowsTheNewestLoadSample() async throws {
        let stub = DetailStubServer()
        stub.reply(path: "/statistics/resources", body: ["MediaContainer": ["size": 2, "StatisticsResources": [
            ["at": 200, "hostCpuUtilization": 40.5, "processCpuUtilization": 12.0],
            ["at": 100, "hostCpuUtilization": 90.0, "processCpuUtilization": 80.0],
        ]]])
        let sample = try await LibraryManagement.load(api: stub.client)
        #expect(sample?.at == 200)
        #expect(sample?.processCpuUtilization == 12.0)
    }

    @Test func activitiesReadProgressWhateverTheServerSendsItAs() async throws {
        let stub = DetailStubServer()
        stub.reply(path: "/activities", body: ["MediaContainer": ["size": 2, "Activity": [
            ["uuid": "a", "type": "library.update.section", "cancellable": true, "title": "Scanning Movies", "progress": 42],
            ["uuid": "b", "title": "Refreshing", "progress": "7"],
        ]]])
        let activities = try await LibraryManagement.activities(api: stub.client)
        #expect(activities.map(\.uuid) == ["a", "b"])
        #expect(activities[0].progress == 42)
        #expect(activities[0].cancellable == true)
        #expect(activities[1].progress == 7)
        #expect(activities[1].cancellable == nil)
    }

    @Test func deletingAHistoryRowUsesTheIdAtTheEndOfItsKey() async throws {
        let stub = DetailStubServer()
        stub.reply(path: "/status/sessions/history/314", body: [:])
        try await LibraryManagement.deleteHistoryEntry(historyKey: "/status/sessions/history/314", api: stub.client)
        #expect(stub.requests.last == "/status/sessions/history/314")
    }

    @Test func savingAnEditSendsOnlyWhatChanged() async throws {
        let stub = DetailStubServer()
        stub.reply(path: "/library/sections/1/all", body: [:])
        var edit = MetadataEdit(item: DetailFixtures.item(["ratingKey": "9", "title": "Dune", "summary": "Sand.", "year": 2021]), sectionId: "1")
        edit.summary = "Spice."
        try await LibraryManagement.edit(edit, api: stub.client)
        let sent = try #require(stub.requestedURLs.last.flatMap(URLComponents.init(string:)))
        let fields = Dictionary(uniqueKeysWithValues: (sent.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(fields == ["type": "1", "id": "9", "summary.value": "Spice.", "summary.locked": "1"])
    }

    @Test func anUnchangedEditSendsNothing() async throws {
        let stub = DetailStubServer()
        let edit = MetadataEdit(item: DetailFixtures.item(["ratingKey": "9", "title": "Dune"]), sectionId: "1")
        try await LibraryManagement.edit(edit, api: stub.client)
        #expect(stub.requests.isEmpty)
    }
}

struct MetadataEditTests {
    @Test func startsFromTheTitleAsItIs() {
        let edit = MetadataEdit(item: DetailFixtures.item(["ratingKey": "9", "title": "Dune", "titleSort": "Dune 1", "originalTitle": "Dune: Part One", "summary": "Sand.", "year": 2021]), sectionId: "1")
        #expect(edit.title == "Dune")
        #expect(edit.sortTitle == "Dune 1")
        #expect(edit.originalTitle == "Dune: Part One")
        #expect(edit.summary == "Sand.")
        #expect(edit.year == "2021")
        #expect(edit.changedValues.isEmpty)
    }

    @Test func aBlankTitleIsNeverSent() {
        var edit = MetadataEdit(item: DetailFixtures.item(["ratingKey": "9", "title": "Dune"]), sectionId: "1")
        edit.title = "   "
        edit.sortTitle = "Dune"
        #expect(edit.changedValues == ["titleSort": "Dune"])
    }

    @Test func onlyAMoviesYearCanBeEdited() {
        var movie = MetadataEdit(item: DetailFixtures.item(["ratingKey": "9", "type": "movie", "title": "Dune", "year": 2021]), sectionId: "1")
        movie.year = "1984"
        #expect(movie.editsYear)
        #expect(movie.changedValues == ["year": "1984"])
        var show = MetadataEdit(item: DetailFixtures.item(["ratingKey": "5", "type": "show", "title": "Severance", "year": 2022]), sectionId: "2")
        show.year = "1999"
        #expect(!show.editsYear)
        #expect(show.changedValues.isEmpty)
    }

    @Test func typeNumbersFollowPlex() {
        let numbers = ["movie", "show", "season", "episode"].map { type in
            MetadataEdit(item: DetailFixtures.item(["type": type]), sectionId: "1").typeNumber
        }
        #expect(numbers == [1, 2, 3, 4])
    }
}

@MainActor
struct ServerOwnershipTests {
    @Test func ownershipIsRememberedPerServer() {
        let owned = "owned-\(UUID().uuidString)"
        let shared = "shared-\(UUID().uuidString)"
        ServerOwnership.setForTesting(true, machineIdentifier: owned)
        ServerOwnership.setForTesting(false, machineIdentifier: shared)
        #expect(ServerOwnership.isOwner(machineIdentifier: owned))
        #expect(!ServerOwnership.isOwner(machineIdentifier: shared))
        #expect(!ServerOwnership.isOwner(machineIdentifier: "unknown-\(UUID().uuidString)"))
        #expect(!ServerOwnership.isOwner(machineIdentifier: nil))
    }

    @Test func sessionRowsCarryTheIdAStreamIsStoppedBy() {
        let row = DetailFixtures.item(["ratingKey": "9", "Session": ["id": "abc", "location": "lan", "bandwidth": 4000]])
        #expect(row.playbackSession?.id == "abc")
        #expect(DetailFixtures.item(["ratingKey": "9"]).playbackSession == nil)
    }
}
