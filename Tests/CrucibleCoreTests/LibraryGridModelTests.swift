import Foundation
import Testing
@testable import CrucibleCore

final class LibraryStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = #"{"MediaContainer":{}}"#
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: @Sendable (URLRequest) -> Reply] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset() {
        lock.withLock {
            routes = [:]
            recorded = []
        }
    }

    static func route(_ path: String, _ reply: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock { routes[path] = reply }
    }

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    static func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "plex.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = self.request
        let reply = Self.lock.withLock { () -> Reply in
            Self.recorded.append(request)
            return Self.routes[request.url?.path ?? ""]?(request) ?? Reply()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self, !self.stopped, let url = request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped = true
    }
}

extension URLRequest {
    func query(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }
}

@MainActor
final class ScrollLog {
    var indexes = [Int]()
}

@Suite(.serialized)
@MainActor
final class LibraryGridModelTests {
    private let all = "/library/sections/1/all"
    private let model: LibraryGridModel
    private var updates: [LibraryGridModel.Update] = []

    init() {
        URLProtocol.registerClass(LibraryStubProtocol.self)
        LibraryStubProtocol.reset()
        model = LibraryGridModel(api: APIClient(baseURL: URL(string: "http://plex.test:32400")!, token: "token"), sectionId: "1", kind: .movie)
        model.onUpdate = { [weak self] update in self?.updates.append(update) }
    }

    deinit {
        URLProtocol.unregisterClass(LibraryStubProtocol.self)
    }

    private func serveItems(total: Int, title: String = "Item") {
        LibraryStubProtocol.route("/library/sections/1/all") { request in
            let start = Int(request.query("X-Plex-Container-Start") ?? "") ?? 0
            let size = Int(request.query("X-Plex-Container-Size") ?? "") ?? 50
            let ids = total > start ? Array(start + 1...min(total, start + size)) : []
            let items = ids.map { #"{"ratingKey":"\#($0)","type":"movie","title":"\#(title) \#($0)"}"# }.joined(separator: ",")
            return .init(body: #"{"MediaContainer":{"totalSize":\#(total),"Metadata":[\#(items)]}}"#)
        }
    }

    private func fail(_ path: String, status: Int = 404) {
        LibraryStubProtocol.route(path) { _ in .init(status: status, body: "") }
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try #require(condition())
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test func appearingLoadsTheFirstPageThroughALoadingState() async throws {
        serveItems(total: 120)
        model.appear()
        #expect(model.contentState == .loading)
        #expect(updates == [.contentState])
        try await until { self.model.contentState == .content }
        #expect(model.gridIds.count == 50)
        #expect(model.pager.serverOffset == 50)
        #expect(model.pager.totalSize == 120)
        #expect(updates.contains(.pageLoaded))
        let first = try #require(LibraryStubProtocol.requests(to: all).first)
        #expect(first.query("sort") == "titleSort:asc")
        #expect(first.query("X-Plex-Container-Start") == "0")
        #expect(first.query("X-Plex-Container-Size") == "50")
    }

    @Test func anEmptyLibraryAndAnEmptyFilterAreDistinguished() async throws {
        serveItems(total: 0)
        model.appear()
        try await until { self.model.contentState == .empty }

        model.setWatch(.unwatched)
        try await until { self.model.contentState == .noMatches }
        #expect(model.options.isFiltering)
    }

    @Test func aFailedFirstPageShowsTheErrorAndRetryRecovers() async throws {
        fail(all)
        model.appear()
        try await until { self.model.contentState != .loading }
        guard case .failed(let message) = model.contentState else {
            Issue.record("expected a failed state, got \(model.contentState)")
            return
        }
        #expect(!message.isEmpty)
        #expect(updates.contains(.pageFailed))
        #expect(!model.pager.isLoading)

        serveItems(total: 3)
        model.refreshAll()
        #expect(model.contentState == .loading)
        try await until { self.model.contentState == .content }
        #expect(model.gridIds == ["1", "2", "3"])
    }

    @Test func laterPagesAppendAndTheirFailuresAreSilent() async throws {
        serveItems(total: 120)
        model.appear()
        try await until { self.model.contentState == .content }

        model.loadNextPageIfNeeded(near: 10)
        #expect(!model.pager.isLoading)
        model.loadNextPageIfNeeded(near: 49)
        #expect(model.pager.isLoading)
        try await until { self.model.gridIds.count == 100 }
        #expect(LibraryStubProtocol.requests(to: all).last?.query("X-Plex-Container-Start") == "50")

        fail(all)
        updates.removeAll()
        model.loadNextPageIfNeeded(near: 99)
        try await until { self.updates.contains(.pageFailed) }
        #expect(model.contentState == .content)
        #expect(model.gridIds.count == 100)
        #expect(!model.pager.isLoading)

        serveItems(total: 120)
        model.loadNextPageIfNeeded(near: 99)
        try await until { self.model.gridIds.count == 120 }
        #expect(model.pager.serverOffset == 120)
        model.loadNextPageIfNeeded(near: 119)
        #expect(!model.pager.isLoading)
    }

    @Test func changingOptionsAnnouncesThemThenReloadsFromTheStart() async throws {
        serveItems(total: 80)
        model.appear()
        try await until { self.model.contentState == .content }
        updates.removeAll()
        let before = LibraryStubProtocol.requests(to: all).count

        model.setSort("year:desc")
        #expect(updates.first == .optionsChanged)
        try await until { self.updates.contains(.pageLoaded) }
        let request = try #require(LibraryStubProtocol.requests(to: all).last)
        #expect(request.query("sort") == "year:desc")
        #expect(request.query("X-Plex-Container-Start") == "0")
        #expect(LibraryStubProtocol.requests(to: all).count == before + 1)

        model.setSort("year:desc")
        try await settle()
        #expect(LibraryStubProtocol.requests(to: all).count == before + 1)
    }

    @Test func chipsAndClearingFiltersReachTheServer() async throws {
        serveItems(total: 5)
        model.appear()
        try await until { self.model.contentState == .content }

        model.setGenre("7")
        model.selectChip(.inProgress)
        try await until { LibraryStubProtocol.requests(to: self.all).last?.query("inProgress") == "1" }
        #expect(LibraryStubProtocol.requests(to: all).last?.query("genre") == "7")

        model.selectChip(.all)
        try await until { LibraryStubProtocol.requests(to: self.all).last?.query("genre") == nil }
        #expect(!model.options.isFiltering)

        model.setWatch(.unwatched)
        model.clearFilters()
        try await settle()
        #expect(model.options == LibraryGridOptions())
    }

    @Test func theContinueItemAndTheRailAreLoadedAndReconciled() async throws {
        serveItems(total: 3)
        LibraryStubProtocol.route("/hubs/sections/1") { _ in
            .init(body: #"{"MediaContainer":{"Hub":[{"hubIdentifier":"movie.inprogress.1","Metadata":[{"ratingKey":"2","type":"movie","title":"Halfway","viewOffset":5000,"duration":60000}]}]}}"#)
        }
        LibraryStubProtocol.route("/status/sessions/history/all") { _ in
            .init(body: #"{"MediaContainer":{"Metadata":[{"ratingKey":"2","type":"movie","title":"Halfway","viewedAt":20},{"ratingKey":"3","type":"movie","title":"Third","viewedAt":10}]}}"#)
        }
        model.appear()
        try await until { self.model.continueItem != nil && !self.model.recentItems.isEmpty }
        #expect(model.continueItem?.id == "2")
        #expect(updates.contains(.continueItem))
        #expect(updates.contains(.recents))
        #expect(model.recentItems.map(\.id) == ["2", "3"])
        #expect(model.visibleRecents.map(\.id) == ["3"])
        #expect(model.recentItem(withId: "3")?.title == "Third")
        #expect(model.recentItem(withId: "99") == nil)

        model.setWatch(.unwatched)
        #expect(model.visibleRecents.isEmpty)
    }

    @Test func genresAreListedFromTheSection() async throws {
        LibraryStubProtocol.route("/library/sections/1/genre") { _ in
            .init(body: #"{"MediaContainer":{"Directory":[{"key":"7","title":"Drama"},{"title":"No key"},{"key":"8","title":"Comedy"}]}}"#)
        }
        model.loadGenres()
        try await until { !self.model.genres.isEmpty }
        #expect(model.genres == [LibraryGenre(key: "7", title: "Drama"), LibraryGenre(key: "8", title: "Comedy")])
        #expect(updates == [.genres])
    }

    @Test func jumpingToALetterLoadsTheSectionUpToItThenScrolls() async throws {
        serveItems(total: 120)
        LibraryStubProtocol.route("/library/sections/1/firstCharacter") { _ in
            .init(body: #"{"MediaContainer":{"Directory":[{"key":"a","size":60},{"key":"b","size":60}]}}"#)
        }
        model.appear()
        try await until { self.model.contentState == .content && self.model.offersAlphabetJump }
        #expect(model.letter(atGridIndex: 10) == "A")

        let scrolled = ScrollLog()
        model.jump(to: "A") { scrolled.indexes.append($0) }
        #expect(scrolled.indexes == [0])

        model.jump(to: "B") { scrolled.indexes.append($0) }
        try await until { scrolled.indexes.count == 2 }
        #expect(scrolled.indexes == [0, 60])
        let request = try #require(LibraryStubProtocol.requests(to: all).last)
        #expect(request.query("X-Plex-Container-Start") == "50")
        #expect(request.query("X-Plex-Container-Size") == "60")
        #expect(model.gridIds.count == 110)
        #expect(model.letter(atGridIndex: 60) == "B")
    }

    @Test func theAlphabetIsOfferedOnlyWhenItLinesUpWithTheGrid() async throws {
        serveItems(total: 120)
        LibraryStubProtocol.route("/library/sections/1/firstCharacter") { _ in
            .init(body: #"{"MediaContainer":{"Directory":[{"key":"a","size":60},{"key":"b","size":60}]}}"#)
        }
        #expect(!model.offersAlphabetJump)
        model.appear()
        try await until { self.model.offersAlphabetJump }
        model.setSort("year:desc")
        #expect(!model.offersAlphabetJump)
    }

    @Test func aFailedAlphabetFetchLeavesAnUnusableIndex() async throws {
        fail("/library/sections/1/firstCharacter")
        serveItems(total: 5)
        model.appear()
        try await until { self.updates.contains(.alphabet) }
        #expect(model.alphabet?.isUsable == false)
        #expect(!model.offersAlphabetJump)
        let scrolled = ScrollLog()
        model.jump(to: "B") { scrolled.indexes.append($0) }
        #expect(scrolled.indexes.isEmpty)
    }

    @Test func comingBackReloadsEveryPageAlreadyLoadedInOneRequest() async throws {
        serveItems(total: 300)
        model.appear()
        try await until { self.model.contentState == .content }
        model.loadNextPageIfNeeded(near: 49)
        try await until { self.model.gridIds.count == 100 }

        model.disappear()
        model.appear()
        try await until { LibraryStubProtocol.requests(to: self.all).last?.query("X-Plex-Container-Size") == "100" }
        let request = try #require(LibraryStubProtocol.requests(to: all).last)
        #expect(request.query("X-Plex-Container-Start") == "0")
        try await until { !self.model.pager.isLoading }
        #expect(model.gridIds.count == 100)
        #expect(model.contentState == .content)
    }

    @Test func leavingCancelsTheFetchInFlight() async throws {
        LibraryStubProtocol.route(all) { _ in
            .init(body: #"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"1","type":"movie","title":"Late"}]}}"#, delay: 0.3)
        }
        model.appear()
        model.disappear()
        #expect(!model.pager.isLoading)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(!updates.contains(.pageLoaded))
        #expect(model.gridIds.isEmpty)
        #expect(!model.pager.hasLoaded)
    }

    @Test func markingWatchedInvalidatesThenReloadsThePagesAndHubs() async throws {
        serveItems(total: 3)
        model.appear()
        try await until { self.model.contentState == .content }
        let pages = LibraryStubProtocol.requests(to: all).count
        let hubs = LibraryStubProtocol.requests(to: "/hubs/sections/1").count

        model.setWatched(ratingKey: "2", watched: true)
        try await until {
            LibraryStubProtocol.requests(to: self.all).count > pages
                && LibraryStubProtocol.requests(to: "/hubs/sections/1").count > hubs
        }
        let scrobble = try #require(LibraryStubProtocol.requests(to: "/:/scrobble").last)
        #expect(scrobble.query("key") == "2")

        model.setWatched(ratingKey: "2", watched: false)
        try await until { !LibraryStubProtocol.requests(to: "/:/unscrobble").isEmpty }
    }
}
