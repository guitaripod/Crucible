import Foundation
import Testing
@testable import CrucibleCore

@Suite(.serialized)
@MainActor
final class LibraryVisibilityTests {
    private nonisolated static let keys = ["knownLibraries", "libraryOverrides"]

    init() {
        Self.clear()
    }

    deinit {
        Self.clear()
    }

    private nonisolated static func clear() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func record(_ json: String) throws {
        let directories = try JSONDecoder().decode([PlexDirectory].self, from: Data(json.utf8))
        LibraryVisibility.record(directories: directories)
    }

    private let threeLibraries = #"""
    [
        {"key":"1","type":"movie","title":"Movies"},
        {"key":"2","type":"show","title":"Shows","hidden":0},
        {"key":"3","type":"artist","title":"Music","hidden":1}
    ]
    """#

    @Test func plexHiddenFlagSetsTheDefault() throws {
        try record(threeLibraries)
        #expect(LibraryVisibility.libraries.map(\.title) == ["Movies", "Shows", "Music"])
        #expect(LibraryVisibility.isIncluded(1))
        #expect(LibraryVisibility.isIncluded(2))
        #expect(!LibraryVisibility.isIncluded(3))
        #expect(LibraryVisibility.excluded == [3])
        #expect(LibraryVisibility.isCustomized)
        #expect(!LibraryVisibility.hasOverrides)
    }

    @Test func libraryTabsKeepEveryLibraryWhateverHomeIncludes() throws {
        let json = #"""
        [
            {"key":"1","type":"movie","title":"Movies"},
            {"key":"2","type":"show","title":"Shows"},
            {"key":"3","type":"movie","title":"Holy Grail","hidden":1}
        ]
        """#
        try record(json)
        #expect(LibraryVisibility.setIncluded(2, false))
        #expect(LibraryVisibility.excluded == [2, 3])
        let directories = try JSONDecoder().decode([PlexDirectory].self, from: Data(json.utf8))
        #expect(LibraryTabLayout(directories: directories).tabs.compactMap(\.title) == ["Movies", "Shows", "Holy Grail"])
    }

    @Test func unknownLibrariesAreIncludedByDefault() {
        #expect(LibraryVisibility.isIncluded(99))
        #expect(LibraryVisibility.excluded.isEmpty)
        #expect(!LibraryVisibility.isCustomized)
    }

    @Test func explicitChoiceOverridesThePlexDefaultBothWays() throws {
        try record(threeLibraries)
        #expect(LibraryVisibility.setIncluded(3, true))
        #expect(LibraryVisibility.isIncluded(3))
        #expect(LibraryVisibility.excluded.isEmpty)
        #expect(LibraryVisibility.hasOverrides)

        #expect(LibraryVisibility.setIncluded(1, false))
        #expect(!LibraryVisibility.isIncluded(1))
        #expect(LibraryVisibility.excluded == [1])
    }

    @Test func choosingThePlexDefaultClearsTheOverride() throws {
        try record(threeLibraries)
        #expect(LibraryVisibility.setIncluded(1, false))
        #expect(LibraryVisibility.hasOverrides)
        #expect(LibraryVisibility.setIncluded(1, true))
        #expect(!LibraryVisibility.hasOverrides)
    }

    @Test func lastIncludedLibraryCannotBeExcluded() throws {
        try record(#"[{"key":"1","type":"movie","title":"Movies"},{"key":"2","type":"show","title":"Shows"}]"#)
        #expect(LibraryVisibility.setIncluded(1, false))
        #expect(!LibraryVisibility.setIncluded(2, false))
        #expect(LibraryVisibility.isIncluded(2))
        #expect(LibraryVisibility.excluded == [1])
    }

    @Test func resetReturnsToPlexDefaults() throws {
        try record(threeLibraries)
        LibraryVisibility.setIncluded(3, true)
        LibraryVisibility.setIncluded(1, false)
        LibraryVisibility.resetToPlexDefaults()
        #expect(!LibraryVisibility.hasOverrides)
        #expect(LibraryVisibility.excluded == [3])
    }

    @Test func observersHearChangesUntilRemoved() throws {
        try record(threeLibraries)
        var calls = 0
        let token = LibraryVisibility.addObserver { calls += 1 }
        LibraryVisibility.setIncluded(3, true)
        LibraryVisibility.resetToPlexDefaults()
        #expect(calls == 2)
        LibraryVisibility.removeObserver(token)
        LibraryVisibility.setIncluded(3, true)
        #expect(calls == 2)
    }

    @Test func recordIgnoresEmptyUnchangedAndIncompleteLists() throws {
        try record(threeLibraries)
        var calls = 0
        let token = LibraryVisibility.addObserver { calls += 1 }
        try record(threeLibraries)
        try record("[]")
        try record(#"[{"type":"movie"},{"key":"x","title":"Bad id"}]"#)
        #expect(calls == 0)
        #expect(LibraryVisibility.libraries.count == 3)
        LibraryVisibility.removeObserver(token)
    }

    @Test func recordRefreshesTheKnownListAndNotifies() throws {
        try record(threeLibraries)
        var calls = 0
        let token = LibraryVisibility.addObserver { calls += 1 }
        try record(#"[{"key":"1","type":"movie","title":"Films"}]"#)
        #expect(calls == 1)
        #expect(LibraryVisibility.libraries.map(\.title) == ["Films"])
        LibraryVisibility.removeObserver(token)
    }

    @Test func librarySymbolFollowsType() {
        func symbol(_ type: String) -> String {
            LibraryVisibility.Library(id: 1, title: "x", type: type, hiddenOnPlex: false).symbol
        }
        #expect(symbol("movie") == "film")
        #expect(symbol("show") == "tv")
        #expect(symbol("artist") == "music.note")
        #expect(symbol("photo") == "photo")
        #expect(symbol("other") == "rectangle.stack")
    }
}
