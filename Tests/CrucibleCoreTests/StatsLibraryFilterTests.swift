import Testing
@testable import CrucibleCore
@testable import CrucibleStats

struct StatsLibraryFilterTests {
    private let movies = LibraryVisibility.Library(id: 1, title: "Movies", type: "movie", hiddenOnPlex: false)
    private let shows = LibraryVisibility.Library(id: 2, title: "Shows", type: "show", hiddenOnPlex: false)
    private let music = LibraryVisibility.Library(id: 3, title: "Music", type: "artist", hiddenOnPlex: true)

    @Test func entriesCarryTheirStateAndPlexHint() {
        let filter = StatsLibraryFilter(libraries: [movies, shows, music], isIncluded: { $0 != 3 }, isCustomized: true, hasOverrides: false)
        #expect(filter.entries.map(\.title) == ["Movies", "Shows", "Music"])
        #expect(filter.entries.map(\.isIncluded) == [true, true, false])
        #expect(filter.entries.map(\.symbol) == ["film", "tv", "music.note"])
        #expect(filter.entries.map(\.subtitle) == [nil, nil, "Hidden from Home in Plex"])
        #expect(filter.entries.map(\.isLocked) == [false, false, false])
    }

    @Test func theLastIncludedLibraryCannotBeSwitchedOff() {
        let filter = StatsLibraryFilter(libraries: [movies, shows], isIncluded: { $0 == 2 }, isCustomized: true, hasOverrides: true)
        #expect(filter.entries.map(\.isLocked) == [false, true])
    }

    @Test func filterIsOnlyAvailableWithAChoiceToMake() {
        #expect(!StatsLibraryFilter(libraries: [movies], isIncluded: { _ in true }, isCustomized: false, hasOverrides: false).isAvailable)
        #expect(StatsLibraryFilter(libraries: [movies, shows], isIncluded: { _ in true }, isCustomized: false, hasOverrides: false).isAvailable)
    }

    @Test func iconAndSpokenValueReflectCustomisation() {
        let plain = StatsLibraryFilter(libraries: [movies, shows], isIncluded: { _ in true }, isCustomized: false, hasOverrides: false)
        let custom = StatsLibraryFilter(libraries: [movies, shows], isIncluded: { $0 == 1 }, isCustomized: true, hasOverrides: true)
        #expect(plain.symbol == "line.3.horizontal.decrease")
        #expect(plain.accessibilityValue == "All libraries")
        #expect(custom.symbol == "line.3.horizontal.decrease.circle.fill")
        #expect(custom.accessibilityValue == "Filtered")
        #expect(custom.hasOverrides)
    }
}
