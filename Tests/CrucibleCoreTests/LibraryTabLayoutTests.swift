import Foundation
import Testing
@testable import CrucibleCore

@Suite
struct LibraryTabLayoutTests {
    private func directories(_ entries: [(key: String, type: String, title: String)]) throws -> [PlexDirectory] {
        let objects = entries.map { #"{"key":"\#($0.key)","type":"\#($0.type)","title":"\#($0.title)"}"# }
        return try JSONDecoder().decode([PlexDirectory].self, from: Data("[\(objects.joined(separator: ","))]".utf8))
    }

    private func titles(_ directories: [PlexDirectory]) -> [String] {
        directories.compactMap(\.title)
    }

    @Test func keepsMovieAndShowLibrariesInServerOrder() throws {
        let all = try directories([("1", "movie", "Movies"), ("2", "show", "TV Shows"), ("3", "movie", "Documentaries")])
        let layout = LibraryTabLayout(directories: all)
        #expect(titles(layout.tabs) == ["Movies", "TV Shows", "Documentaries"])
        #expect(layout.overflow.isEmpty)
        #expect(!layout.hasMore)
    }

    @Test func dropsMusicPhotoAndUnknownTypes() throws {
        let all = try directories([("1", "movie", "Movies"), ("2", "artist", "Music"), ("3", "photo", "Photos"), ("4", "show", "Shows")])
        let layout = LibraryTabLayout(directories: all)
        #expect(titles(layout.tabs) == ["Movies", "Shows"])
    }

    @Test func exactlyTheLimitStaysAsTabs() throws {
        let all = try directories([("1", "movie", "A"), ("2", "show", "B"), ("3", "movie", "C"), ("4", "show", "D")])
        let layout = LibraryTabLayout(directories: all)
        #expect(titles(layout.tabs) == ["A", "B", "C", "D"])
        #expect(!layout.hasMore)
    }

    @Test func overTheLimitKeepsThreeTabsAndMovesTheRestBehindMore() throws {
        let all = try directories([
            ("1", "movie", "A"), ("2", "show", "B"), ("3", "movie", "C"), ("4", "show", "D"), ("5", "movie", "E"),
        ])
        let layout = LibraryTabLayout(directories: all)
        #expect(titles(layout.tabs) == ["A", "B", "C"])
        #expect(titles(layout.overflow) == ["D", "E"])
        #expect(layout.hasMore)
    }

    @Test func skipsEntriesWithoutNumericKeyOrTitle() throws {
        let json = #"[{"key":"x","type":"movie","title":"Bad"},{"key":"7","type":"movie"},{"key":"8","type":"show","title":"Good"}]"#
        let all = try JSONDecoder().decode([PlexDirectory].self, from: Data(json.utf8))
        let layout = LibraryTabLayout(directories: all)
        #expect(titles(layout.tabs) == ["Good"])
    }

    @Test func emptyInputYieldsNoTabs() {
        let layout = LibraryTabLayout(directories: [])
        #expect(layout.tabs.isEmpty)
        #expect(!layout.hasMore)
    }
}
