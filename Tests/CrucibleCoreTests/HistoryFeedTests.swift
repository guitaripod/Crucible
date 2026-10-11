import Foundation
import Testing
@testable import CrucibleCore

private actor FakeHistoryServer {
    enum Reply {
        case page(PlexMediaContainer)
        case fail
        case hang
    }

    struct Failure: Error {}

    private var replies: [Reply]
    private(set) var endpoints: [PlexEndpoint] = []
    private(set) var historyStarts: [Int] = []
    private(set) var historySizes: [Int] = []
    private var metadata: PlexMediaContainer?

    init(replies: [Reply], metadata: PlexMediaContainer? = nil) {
        self.replies = replies
        self.metadata = metadata
    }

    func respond(to endpoint: PlexEndpoint) async throws -> PlexMediaContainer {
        endpoints.append(endpoint)
        switch endpoint {
        case .history(let start, let size, _):
            historyStarts.append(start)
            historySizes.append(size)
            let reply = replies.isEmpty ? Reply.fail : replies.removeFirst()
            switch reply {
            case .page(let container): return container
            case .fail: throw Failure()
            case .hang:
                try await Task.sleep(for: .seconds(60))
                throw Failure()
            }
        case .metadata:
            guard let metadata else { throw Failure() }
            return metadata
        default:
            throw Failure()
        }
    }
}

@MainActor
private final class EventLog {
    var events: [HistoryFeed.Event] = []
}

@MainActor
struct HistoryFeedTests {
    private func makeFeed(_ server: FakeHistoryServer, log: EventLog = EventLog()) -> (HistoryFeed, EventLog) {
        let feed = HistoryFeed(request: { try await server.respond(to: $0) }, now: { HistoryFixtures.now })
        feed.onEvent = { log.events.append($0) }
        return (feed, log)
    }

    private func settle(_ feed: HistoryFeed) async {
        for _ in 0..<200 {
            if !feed.pager.isLoading { return }
            await Task.yield()
        }
    }

    private func rows(_ range: Range<Int>, viewedAt: Int? = nil) -> [String] {
        range.map { HistoryFixtures.json(key: "\($0)", title: "Item \($0)", viewedAt: viewedAt ?? HistoryFixtures.ago(days: 30 + $0)) }
    }

    @Test func firstPageLoadsItemsAndAdvancesThePager() async {
        let server = FakeHistoryServer(replies: [.page(HistoryFixtures.container(total: 120, rows: rows(0..<50)))])
        let (feed, log) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        #expect(feed.pager.isLoading)
        await settle(feed)
        #expect(feed.items.count == 50)
        #expect(feed.pager.offset == 50)
        #expect(feed.pager.total == 120)
        #expect(log.events == [.pageLoaded])
        #expect(await server.historyStarts == [0])
        #expect(await server.historySizes == [50])
    }

    @Test func loadFirstPageIsIdempotentWhileLoadingAndOnceLoaded() async {
        let server = FakeHistoryServer(replies: [.page(HistoryFixtures.container(total: 3, rows: rows(0..<3)))])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        #expect(await server.historyStarts == [0])
    }

    @Test func nextPageAppendsWithOffsetBasedIdentity() async {
        let server = FakeHistoryServer(replies: [
            .page(HistoryFixtures.container(total: 100, rows: rows(0..<50))),
            .page(HistoryFixtures.container(total: 100, rows: rows(0..<50)))
        ])
        let (feed, log) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        feed.prefetchMore()
        await settle(feed)
        #expect(feed.items.count == 100)
        #expect(feed.items[0].uniqueId == "0-0")
        #expect(feed.items[50].uniqueId == "0-50")
        #expect(Set(feed.items.map(\.uniqueId)).count == 100)
        #expect(feed.pager.offset == 100)
        #expect(!feed.pager.hasMore)
        #expect(log.events == [.pageLoaded, .pageLoaded])
        #expect(await server.historyStarts == [0, 50])
    }

    @Test func autoLoadFetchesWhileTheVisibleListIsShort() async {
        let server = FakeHistoryServer(replies: [
            .page(HistoryFixtures.container(total: 100, rows: rows(0..<50))),
            .page(HistoryFixtures.container(total: 100, rows: rows(50..<100)))
        ])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        feed.loadMoreIfNeeded(visibleCount: 50)
        #expect(!feed.pager.isLoading)
        feed.loadMoreIfNeeded(visibleCount: 3)
        #expect(feed.pager.isLoading)
        await settle(feed)
        #expect(feed.items.count == 100)
    }

    @Test func autoLoadKeepsFetchingWhileThisWeekIsStillOpen() async {
        let recent = rows(0..<50, viewedAt: HistoryFixtures.ago(days: 2))
        let server = FakeHistoryServer(replies: [
            .page(HistoryFixtures.container(total: 100, rows: recent)),
            .page(HistoryFixtures.container(total: 100, rows: rows(50..<100)))
        ])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        feed.loadMoreIfNeeded(visibleCount: 50)
        #expect(feed.pager.isLoading)
        await settle(feed)
        #expect(await server.historyStarts == [0, 50])
    }

    @Test func laterPageFailureIsSilentAndKeepsTheItems() async {
        let server = FakeHistoryServer(replies: [
            .page(HistoryFixtures.container(total: 100, rows: rows(0..<50))),
            .fail,
            .page(HistoryFixtures.container(total: 100, rows: rows(50..<100)))
        ])
        let (feed, log) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        feed.prefetchMore()
        await settle(feed)
        #expect(feed.items.count == 50)
        #expect(feed.pager.hasFailed)
        #expect(feed.emptyState(filter: .all) == .populated)
        #expect(log.events == [.pageLoaded, .failed])
        feed.loadMoreIfNeeded(visibleCount: 1)
        #expect(!feed.pager.isLoading)
        feed.prefetchMore()
        await settle(feed)
        #expect(feed.items.count == 100)
        #expect(!feed.pager.hasFailed)
    }

    @Test func firstPageFailureShowsLoadFailedAndRetryRecovers() async {
        let server = FakeHistoryServer(replies: [
            .fail,
            .page(HistoryFixtures.container(total: 2, rows: rows(0..<2)))
        ])
        let (feed, log) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        #expect(feed.emptyState(filter: .all) == .loading)
        await settle(feed)
        #expect(feed.emptyState(filter: .all) == .loadFailed)
        #expect(log.events == [.failed])
        feed.retry()
        await settle(feed)
        #expect(feed.items.count == 2)
        #expect(feed.emptyState(filter: .all) == .populated)
    }

    @Test func emptyHistoryShowsNoActivity() async {
        let server = FakeHistoryServer(replies: [.page(HistoryFixtures.container(total: 0, rows: []))])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        #expect(feed.emptyState(filter: .all) == .noActivity)
    }

    @Test func missingTotalSizeStopsPagingAfterTheFirstPage() async {
        let server = FakeHistoryServer(replies: [.page(HistoryFixtures.container(total: nil, rows: rows(0..<50)))])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        feed.loadMoreIfNeeded(visibleCount: 1)
        feed.prefetchMore()
        #expect(!feed.pager.isLoading)
        #expect(await server.historyStarts == [0])
    }

    @Test func refreshReplacesTheListFromTheTop() async {
        let server = FakeHistoryServer(replies: [
            .page(HistoryFixtures.container(total: 100, rows: rows(0..<50))),
            .page(HistoryFixtures.container(total: 3, rows: rows(900..<903)))
        ])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        feed.refresh()
        #expect(feed.pager.offset == 0)
        #expect(feed.pager.total == 0)
        await settle(feed)
        #expect(feed.items.map(\.ratingKey) == ["900", "901", "902"])
        #expect(feed.pager.offset == 3)
        #expect(await server.historyStarts == [0, 0])
    }

    @Test func refreshSupersedesALoadInFlight() async {
        let server = FakeHistoryServer(replies: [
            .hang,
            .page(HistoryFixtures.container(total: 2, rows: rows(0..<2)))
        ])
        let (feed, log) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await Task.yield()
        feed.refresh()
        await settle(feed)
        #expect(feed.items.count == 2)
        #expect(log.events == [.pageLoaded])
    }

    @Test func cancelStopsTheLoadWithoutAnyEvent() async {
        let server = FakeHistoryServer(replies: [.hang])
        let (feed, log) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await Task.yield()
        feed.cancel()
        #expect(!feed.pager.isLoading)
        for _ in 0..<20 { await Task.yield() }
        #expect(log.events.isEmpty)
        #expect(feed.items.isEmpty)
        #expect(feed.pager.needsFirstPage(isEmpty: feed.items.isEmpty))
    }

    @Test func filtersApplyWithoutRefetching() async {
        let rows = [
            HistoryFixtures.json(key: "1", type: "movie"),
            HistoryFixtures.json(key: "2", type: "episode"),
            HistoryFixtures.json(key: "3", type: "show")
        ]
        let server = FakeHistoryServer(replies: [.page(HistoryFixtures.container(total: 3, rows: rows))])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        #expect(feed.items(matching: .all).count == 3)
        #expect(feed.items(matching: .movies).map(\.ratingKey) == ["1"])
        #expect(feed.items(matching: .tv).map(\.ratingKey) == ["2", "3"])
        #expect(await server.historyStarts == [0])
    }

    @Test func filterWithNoMatchesShowsItsEmptyStateOnceLoaded() async {
        let server = FakeHistoryServer(replies: [.page(HistoryFixtures.container(total: 1, rows: [HistoryFixtures.json(key: "1", type: "movie")]))])
        let (feed, _) = makeFeed(server)
        feed.loadFirstPageIfNeeded()
        await settle(feed)
        #expect(feed.emptyState(filter: .tv) == .noMatches(.tv))
        #expect(feed.emptyState(filter: .movies) == .populated)
    }

    @Test func playAgainFetchesTheMetadataForTheRatingKey() async throws {
        let details = HistoryFixtures.container(total: 1, rows: [HistoryFixtures.json(key: "42", title: "Full details")])
        let server = FakeHistoryServer(replies: [], metadata: details)
        let (feed, _) = makeFeed(server)
        let metadata = try #require(await feed.metadata(for: HistoryFixtures.item(key: "42")))
        #expect(metadata.title == "Full details")
        let endpoints = await server.endpoints
        #expect(endpoints.count == 1)
        if case .metadata(let ratingKey) = endpoints[0] { #expect(ratingKey == "42") } else { Issue.record("expected a metadata request") }
    }

    @Test func playAgainReturnsNilWhenTheServerHasNoRow() async throws {
        let server = FakeHistoryServer(replies: [], metadata: HistoryFixtures.container(total: 0, rows: []))
        let (feed, _) = makeFeed(server)
        #expect(try await feed.metadata(for: HistoryFixtures.item(key: "1")) == nil)
    }

    @Test func playAgainPropagatesRequestFailures() async {
        let server = FakeHistoryServer(replies: [])
        let (feed, _) = makeFeed(server)
        await #expect(throws: FakeHistoryServer.Failure.self) {
            _ = try await feed.metadata(for: HistoryFixtures.item(key: "1"))
        }
    }
}
