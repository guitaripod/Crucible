import Foundation
import Testing
@testable import CrucibleCore

struct LibraryGridPagerTests {
    private func items(_ range: ClosedRange<Int>) throws -> [PlexMetadata] {
        let json = "[" + range.map { #"{"ratingKey":"\#($0)","type":"movie","title":"Item \#($0)"}"# }.joined(separator: ",") + "]"
        return try LibraryFixtures.items(json)
    }

    private func loaded(count: Int, total: Int) throws -> LibraryGridPager {
        var pager = LibraryGridPager()
        pager.apply(items: try items(1...count), offset: 0, totalSize: total)
        return pager
    }

    @Test func constantsMatchThePageSizeAndPrefetchWindow() {
        #expect(LibraryGridPager.pageSize == 50)
        #expect(LibraryGridPager.prefetchThreshold == 10)
    }

    @Test func firstPageFillsTheGrid() throws {
        var pager = LibraryGridPager()
        #expect(!pager.hasLoaded)
        pager.beginFetch()
        #expect(pager.isLoading)
        pager.apply(items: try items(1...50), offset: 0, totalSize: 120)
        #expect(pager.ids.count == 50)
        #expect(pager.ids.first == "1")
        #expect(pager.serverOffset == 50)
        #expect(pager.totalSize == 120)
        #expect(pager.hasLoaded)
        #expect(!pager.isLoading)
        #expect(pager.item(withId: "7")?.title == "Item 7")
        #expect(pager.item(withId: "999") == nil)
    }

    @Test func laterPagesAppendInOrder() throws {
        var pager = try loaded(count: 50, total: 120)
        pager.apply(items: try items(51...100), offset: 50, totalSize: 120)
        #expect(pager.ids.count == 100)
        #expect(pager.ids.last == "100")
        #expect(pager.serverOffset == 100)
    }

    @Test func duplicatesKeepTheirFirstPositionButRefreshTheirData() throws {
        var pager = try loaded(count: 3, total: 10)
        let repeated = try LibraryFixtures.items(#"[{"ratingKey":"2","type":"movie","title":"Renamed"},{"ratingKey":"4","type":"movie","title":"Four"}]"#)
        pager.apply(items: repeated, offset: 3, totalSize: 10)
        #expect(pager.ids == ["1", "2", "3", "4"])
        #expect(pager.item(withId: "2")?.title == "Renamed")
        #expect(pager.serverOffset == 5)
    }

    @Test func itemsWithoutAnIdAreNeverShown() throws {
        var pager = LibraryGridPager()
        let json = #"[{"title":"Nameless"},{"ratingKey":"1","title":"One"},{"ratingKey":"1","title":"One again"}]"#
        pager.apply(items: try LibraryFixtures.items(json), offset: 0, totalSize: 3)
        #expect(pager.ids == ["1"])
        pager.apply(items: try LibraryFixtures.items(#"[{"title":"Nameless"}]"#), offset: 3, totalSize: 3)
        #expect(pager.ids == ["1"])
    }

    @Test func pageOneReplacesEverythingLoaded() throws {
        var pager = try loaded(count: 50, total: 50)
        pager.apply(items: try items(60...62), offset: 0, totalSize: 3)
        #expect(pager.ids == ["60", "61", "62"])
        #expect(pager.item(withId: "1") == nil)
        #expect(pager.serverOffset == 3)
    }

    @Test func aMissingTotalMeansNothingMoreToLoad() throws {
        var pager = LibraryGridPager()
        pager.apply(items: try items(1...5), offset: 0, totalSize: 0)
        #expect(!pager.shouldLoadNextPage(near: 4))
    }

    @Test func nextPageIsDueWithinTheTenLastItems() throws {
        let pager = try loaded(count: 50, total: 120)
        #expect(!pager.shouldLoadNextPage(near: 0))
        #expect(!pager.shouldLoadNextPage(near: 39))
        #expect(pager.shouldLoadNextPage(near: 40))
        #expect(pager.shouldLoadNextPage(near: 49))
    }

    @Test func noNextPageWhileLoadingOrAtTheEnd() throws {
        var pager = try loaded(count: 50, total: 120)
        pager.beginFetch()
        #expect(!pager.shouldLoadNextPage(near: 49))
        pager.endFetch()
        #expect(pager.shouldLoadNextPage(near: 49))

        let finished = try loaded(count: 50, total: 50)
        #expect(!finished.shouldLoadNextPage(near: 49))
    }

    @Test func reloadRefetchesEverythingAlreadyLoadedButAtLeastOnePage() throws {
        #expect(LibraryGridPager().reloadSize == 50)
        #expect(try loaded(count: 20, total: 20).reloadSize == 50)
        var pager = try loaded(count: 50, total: 300)
        pager.apply(items: try items(51...100), offset: 50, totalSize: 300)
        pager.apply(items: try items(101...150), offset: 100, totalSize: 300)
        #expect(pager.reloadSize == 150)
    }

    @Test func jumpingInsideTheLoadedPagesJustScrolls() throws {
        let pager = try loaded(count: 50, total: 300)
        #expect(pager.jumpPlan(toOffset: 0) == .scroll(toIndex: 0))
        #expect(pager.jumpPlan(toOffset: 49) == .scroll(toIndex: 49))
    }

    @Test func jumpingPastTheLoadedPagesReadsUpToTheTarget() throws {
        let pager = try loaded(count: 50, total: 300)
        #expect(pager.jumpPlan(toOffset: 50) == .loadThenScroll(size: 50))
        #expect(pager.jumpPlan(toOffset: 180) == .loadThenScroll(size: 180))
    }

    @Test func jumpingWhenTheServerHasNoMoreScrollsToTheEnd() throws {
        let pager = try loaded(count: 30, total: 30)
        #expect(pager.jumpPlan(toOffset: 31) == .scroll(toIndex: 29))
    }

    @Test func aShallowGridIsRefetchedWholeOnReturn() throws {
        let pager = try loaded(count: 50, total: 300)
        #expect(pager.reloadPlan(anchor: 40) == .refetchLoaded(size: 50))
        #expect(LibraryGridPager().reloadPlan(anchor: 0) == .refetchLoaded(size: 50))
    }

    @Test func aDeepGridRefreshesOnlyAWindowAroundTheUser() throws {
        var pager = LibraryGridPager()
        pager.apply(items: try items(1...400), offset: 0, totalSize: 5_000)
        #expect(pager.reloadPlan(anchor: 250) == .refreshWindow(offset: 150, size: 200))
        #expect(pager.reloadPlan(anchor: 0) == .refreshWindow(offset: 0, size: 200))
        #expect(pager.reloadPlan(anchor: 399) == .refreshWindow(offset: 200, size: 200))
        #expect(pager.reloadPlan(anchor: 9_999) == .refreshWindow(offset: 200, size: 200))
    }

    @Test func mergingRefreshesLoadedItemsWithoutMovingAnything() throws {
        var pager = try loaded(count: 3, total: 10)
        let fresh = try LibraryFixtures.items(#"[{"ratingKey":"2","type":"movie","title":"Renamed","viewCount":1},{"ratingKey":"99","type":"movie","title":"Stranger"}]"#)
        pager.beginFetch()
        pager.merge(items: fresh)
        #expect(pager.ids == ["1", "2", "3"])
        #expect(pager.item(withId: "2")?.title == "Renamed")
        #expect(pager.item(withId: "99") == nil)
        #expect(pager.serverOffset == 3)
        #expect(!pager.isLoading)
    }

    @Test func jumpingInAnEmptyGridNeverAimsBelowZero() {
        let pager = LibraryGridPager()
        #expect(pager.jumpPlan(toOffset: 5) == .scroll(toIndex: 0))
    }

    @Test func endingAFetchClearsTheLoadingFlag() {
        var pager = LibraryGridPager()
        pager.beginFetch()
        pager.endFetch()
        #expect(!pager.isLoading)
        #expect(!pager.hasLoaded)
    }
}
