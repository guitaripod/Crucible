import Foundation
import Testing
@testable import CrucibleCore

struct HistoryPagerTests {
    private let now = HistoryFixtures.now

    private func loaded(offset: Int = 50, total: Int = 200) -> HistoryPager {
        var pager = HistoryPager()
        pager.beginLoading()
        pager.finishLoading(offset: offset - 50, count: 50, total: total)
        return pager
    }

    @Test func startsIdleAndEmpty() {
        let pager = HistoryPager()
        #expect(pager.offset == 0)
        #expect(pager.total == 0)
        #expect(!pager.hasMore)
        #expect(!pager.isLoading)
        #expect(!pager.hasFailed)
        #expect(pager.needsFirstPage(isEmpty: true))
        #expect(!pager.needsFirstPage(isEmpty: false))
    }

    @Test func firstPageIsNotRequestedWhileLoading() {
        var pager = HistoryPager()
        pager.beginLoading()
        #expect(!pager.needsFirstPage(isEmpty: true))
    }

    @Test func finishingAdvancesTheOffsetAndRecordsTheTotal() {
        let pager = loaded(offset: 50, total: 120)
        #expect(pager.offset == 50)
        #expect(pager.total == 120)
        #expect(pager.hasMore)
        #expect(!pager.isLoading)
    }

    @Test func missingTotalStopsPaging() {
        var pager = HistoryPager()
        pager.beginLoading()
        pager.finishLoading(offset: 0, count: 50, total: nil)
        #expect(pager.total == 0)
        #expect(!pager.hasMore)
        var other = pager
        #expect(other.claimNextPage(visibleCount: 3, oldestViewedAt: nil, now: now) == nil)
        #expect(other.claimPrefetchPage() == nil)
    }

    @Test func reachingTheTotalStopsPaging() {
        let pager = loaded(offset: 50, total: 50)
        #expect(!pager.hasMore)
    }

    @Test func failureIsRememberedAndClearedBySuccess() {
        var pager = HistoryPager()
        pager.beginLoading()
        pager.failLoading()
        #expect(pager.hasFailed)
        #expect(!pager.isLoading)
        pager.beginLoading()
        pager.finishLoading(offset: 0, count: 1, total: 1)
        #expect(!pager.hasFailed)
    }

    @Test func resetRewindsEverythingButTheLoadingFlag() {
        var pager = loaded(offset: 100, total: 300)
        pager.beginLoading()
        pager.failLoading()
        pager.reset()
        #expect(pager.offset == 0)
        #expect(pager.total == 0)
        #expect(!pager.hasFailed)
        #expect(!pager.isLoadingMore)
    }

    @Test func shortVisibleListClaimsTheNextPage() {
        var pager = loaded()
        #expect(pager.claimNextPage(visibleCount: 11, oldestViewedAt: HistoryFixtures.ago(days: 30), now: now) == 50)
        #expect(pager.isLoadingMore)
    }

    @Test func fullVisibleListWithOldHistoryDoesNotClaim() {
        var pager = loaded()
        #expect(pager.claimNextPage(visibleCount: 12, oldestViewedAt: HistoryFixtures.ago(days: 8), now: now) == nil)
        #expect(!pager.isLoadingMore)
    }

    @Test func oldestPlayInsideTheWeekKeepsFetchingForTheSummary() {
        var pager = loaded()
        #expect(pager.claimNextPage(visibleCount: 40, oldestViewedAt: HistoryFixtures.ago(days: 3), now: now) == 50)
    }

    @Test func oldestExactlyOneWeekAgoStillCounts() {
        var pager = loaded()
        #expect(pager.claimNextPage(visibleCount: 40, oldestViewedAt: HistoryFixtures.ago(days: 7), now: now) == 50)
    }

    @Test func undatedOldestIsTreatedAsZero() {
        var pager = loaded()
        #expect(pager.claimNextPage(visibleCount: 40, oldestViewedAt: nil, now: now) == nil)
        #expect(pager.claimNextPage(visibleCount: 5, oldestViewedAt: nil, now: now) == 50)
    }

    @Test func claimIsExclusiveWhileALoadIsRunning() {
        var pager = loaded()
        #expect(pager.claimNextPage(visibleCount: 1, oldestViewedAt: nil, now: now) == 50)
        #expect(pager.claimNextPage(visibleCount: 1, oldestViewedAt: nil, now: now) == nil)
        #expect(pager.claimPrefetchPage() == nil)
    }

    @Test func claimWaitsForARunningLoad() {
        var pager = loaded()
        pager.beginLoading()
        #expect(pager.claimNextPage(visibleCount: 1, oldestViewedAt: nil, now: now) == nil)
    }

    @Test func claimStopsAtTheEnd() {
        var pager = loaded(offset: 50, total: 50)
        #expect(pager.claimNextPage(visibleCount: 1, oldestViewedAt: nil, now: now) == nil)
    }

    @Test func autoLoadRespectsAFailureButPrefetchRetries() {
        var pager = loaded()
        pager.beginLoading()
        pager.failLoading()
        #expect(pager.claimNextPage(visibleCount: 1, oldestViewedAt: nil, now: now) == nil)
        #expect(pager.claimPrefetchPage() == 50)
    }

    @Test func cancelClearsBothLoadingFlags() {
        var pager = loaded()
        _ = pager.claimPrefetchPage()
        pager.beginLoading()
        pager.cancelLoading()
        #expect(!pager.isLoading)
        #expect(!pager.isLoadingMore)
        #expect(pager.claimPrefetchPage() == 50)
    }

    @Test func prefetchWindowIsTheLastTenPositions() {
        #expect(HistoryPager.isWithinPrefetchWindow(position: 40, count: 50))
        #expect(HistoryPager.isWithinPrefetchWindow(position: 49, count: 50))
        #expect(!HistoryPager.isWithinPrefetchWindow(position: 39, count: 50))
        #expect(HistoryPager.isWithinPrefetchWindow(position: 0, count: 8))
    }

    @Test func emptyStateTable() {
        var pager = HistoryPager()
        #expect(pager.emptyState(isEmpty: true, visibleIsEmpty: true, filter: .all) == .noActivity)
        pager.beginLoading()
        #expect(pager.emptyState(isEmpty: true, visibleIsEmpty: true, filter: .all) == .loading)
        pager.failLoading()
        #expect(pager.emptyState(isEmpty: true, visibleIsEmpty: true, filter: .all) == .loadFailed)
        pager.beginLoading()
        #expect(pager.emptyState(isEmpty: true, visibleIsEmpty: true, filter: .all) == .loading)
    }

    @Test func filterWithNoMatchesOnlyShowsOnceEverythingIsLoaded() {
        let exhausted = loaded(offset: 50, total: 50)
        let more = loaded(offset: 50, total: 200)
        #expect(exhausted.emptyState(isEmpty: false, visibleIsEmpty: true, filter: .movies) == .noMatches(.movies))
        #expect(exhausted.emptyState(isEmpty: false, visibleIsEmpty: true, filter: .tv) == .noMatches(.tv))
        #expect(more.emptyState(isEmpty: false, visibleIsEmpty: true, filter: .movies) == .populated)
        #expect(exhausted.emptyState(isEmpty: false, visibleIsEmpty: false, filter: .movies) == .populated)
    }

    @Test func emptyStateCopy() {
        #expect(HistoryEmptyState.populated.content == nil)
        #expect(HistoryEmptyState.loading.content == nil)
        #expect(HistoryEmptyState.noActivity.content == .init(
            symbolName: "clock", title: "No activity yet", message: "Movies and episodes you watch will show up here."
        ))
        #expect(HistoryEmptyState.loadFailed.content == .init(
            symbolName: "wifi.exclamationmark", title: "Couldn't load history", message: "Check your connection and try again."
        ))
        #expect(HistoryEmptyState.noMatches(.movies).content == .init(symbolName: "film", title: "No movies watched yet", message: nil))
        #expect(HistoryEmptyState.noMatches(.tv).content == .init(symbolName: "tv", title: "No TV watched yet", message: nil))
    }
}
