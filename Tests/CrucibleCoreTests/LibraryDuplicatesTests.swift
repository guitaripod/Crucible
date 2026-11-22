import Foundation
import Testing

@testable import CrucibleCore

@Suite("Library duplicates")
struct LibraryDuplicatesTests {
    private static func video(_ id: String, _ title: String, seconds: Int, container: String = "mp4", height: Int = 480, guid: String? = nil, year: Int? = nil) -> PlexMetadata {
        var fields: [String: Any] = [
            "ratingKey": id, "title": title, "duration": seconds * 1000,
            "guid": guid ?? "local://\(id)",
            "Media": [["container": container, "height": height, "bitrate": 1000]],
        ]
        if let year { fields["year"] = year }
        return DetailFixtures.item(fields)
    }

    @Test func foldsFormatsAndFoldersOfOneVideoShowingTheOneThatPlaysBest() {
        let items = [
            Self.video("17116", "!About Face 2 384p", seconds: 1258, container: "avi"),
            Self.video("20531", "!About Face 2 384p", seconds: 1258),
            Self.video("17117", "!BabyGotBoobs", seconds: 3381),
            Self.video("18176", "1-1-01", seconds: 128),
            Self.video("18543", "1-1-01", seconds: 128, container: "mpeg"),
            Self.video("21005", "1-1-01", seconds: 129),
        ]
        #expect(LibraryDuplicates.folded(items).map(\.id) == ["20531", "17117", "18176"])
    }

    @Test func keepsDifferentVideosThatShareAName() {
        let items = [
            Self.video("1", "Scene", seconds: 600), Self.video("2", "Scene", seconds: 900),
            Self.video("3", "Heat", seconds: 10200, guid: "local://3", year: 1995), Self.video("4", "Heat", seconds: 10200, guid: "local://4", year: 1986),
        ]
        #expect(LibraryDuplicates.folded(items).count == 4)
    }

    @Test func foldsMatchedCopiesByGuidPreferringTheSharperPicture() {
        let items = [
            Self.video("1", "Monty Python and the Holy Grail", seconds: 5500, height: 1080, guid: "plex://movie/abc"),
            Self.video("2", "Monty Python & the Holy Grail", seconds: 5320, height: 2160, guid: "plex://movie/abc"),
        ]
        #expect(LibraryDuplicates.folded(items).map(\.id) == ["2"])
    }

    @Test func thePagerFoldsAcrossPagesAndMapsSectionOffsetsToCells() {
        var pager = LibraryGridPager(foldsCopies: true)
        pager.apply(items: [Self.video("a", "A", seconds: 60, container: "avi"), Self.video("b", "B", seconds: 60)], offset: 0, totalSize: 4)
        pager.apply(items: [Self.video("a2", "A", seconds: 60), Self.video("c", "C", seconds: 60)], offset: 2, totalSize: 4)
        #expect(pager.ids == ["a2", "b", "c"])
        #expect(pager.copies(of: "a2").map(\.id) == ["a"])
        #expect(pager.index(ofOffset: 3) == 2)
        #expect(pager.jumpPlan(toOffset: 3) == .scroll(toIndex: 2))
        #expect(pager.serverOffset == 4)
    }

    @Test func thePagerLeavesCopiesAloneWhenMergingIsOff() {
        var pager = LibraryGridPager(foldsCopies: false)
        pager.apply(items: [Self.video("a", "A", seconds: 60), Self.video("a2", "A", seconds: 60)], offset: 0, totalSize: 2)
        #expect(pager.ids == ["a", "a2"])
    }
}
