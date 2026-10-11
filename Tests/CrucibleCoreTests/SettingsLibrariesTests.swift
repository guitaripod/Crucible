import Foundation
import Testing
@testable import CrucibleCore

struct SettingsLibrariesTests {
    private typealias Library = LibraryVisibility.Library

    private let movies = Library(id: 1, title: "Movies", type: "movie", hiddenOnPlex: false)
    private let shows = Library(id: 2, title: "Shows", type: "show", hiddenOnPlex: false)
    private let music = Library(id: 3, title: "Music", type: "artist", hiddenOnPlex: true)

    @Test func rowsCarryTitleSymbolAndTheHiddenHint() {
        let rows = LibrariesSettings.rows(for: [movies, music], isIncluded: { $0 == 1 })
        #expect(rows.map(\.title) == ["Movies", "Music"])
        #expect(rows.map(\.symbol) == ["film", "music.note"])
        #expect(rows.map(\.subtitle) == [nil, "Hidden from Home in Plex"])
        #expect(rows.map(\.isIncluded) == [true, false])
    }

    @Test func theLastIncludedLibraryIsLocked() {
        let rows = LibrariesSettings.rows(for: [movies, shows, music], isIncluded: { $0 == 2 })
        #expect(rows.map(\.isLocked) == [false, true, false])
    }

    @Test func nothingIsLockedWhileSeveralLibrariesAreIncluded() {
        let rows = LibrariesSettings.rows(for: [movies, shows, music], isIncluded: { $0 != 3 })
        #expect(rows.allSatisfy { !$0.isLocked })
    }

    @Test func summaryNamesAllOrTheCount() {
        #expect(LibrariesSettings.summary(for: [], isIncluded: { _ in true }) == nil)
        #expect(LibrariesSettings.summary(for: [movies, shows], isIncluded: { _ in true }) == "All")
        #expect(LibrariesSettings.summary(for: [movies, shows, music], isIncluded: { $0 != 3 }) == "2 of 3")
        #expect(LibrariesSettings.summary(for: [movies, shows, music], isIncluded: { $0 == 1 }) == "1 of 3")
    }

    @Test func copyMatchesTheIPhoneScreen() {
        #expect(LibrariesSettings.resetTitle == "Reset to Plex Defaults")
        #expect(LibrariesSettings.loadingTitle == "Loading Libraries")
        #expect(LibrariesSettings.footerText.hasSuffix("At least one library stays on."))
    }
}
