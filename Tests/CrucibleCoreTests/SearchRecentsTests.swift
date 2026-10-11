import Foundation
import Testing
@testable import CrucibleCore

struct SearchRecentsTests {
    @Test func newestFirst() {
        var recents = SearchRecents()
        recents.remember("halo")
        recents.remember("dune")
        #expect(recents.queries == ["dune", "halo"])
    }

    @Test func dedupesCaseInsensitivelyAndMovesToFront() {
        var recents = SearchRecents(["dune", "Halo", "alien"])
        recents.remember("HALO")
        #expect(recents.queries == ["HALO", "dune", "alien"])
    }

    @Test func capsAtEightDroppingTheOldest() {
        var recents = SearchRecents()
        for index in 1...10 { recents.remember("query \(index)") }
        #expect(recents.queries.count == SearchRecents.capacity)
        #expect(recents.queries.first == "query 10")
        #expect(recents.queries.last == "query 3")
        #expect(SearchRecents(Array(repeating: "ab", count: 12)).queries.count == 8)
    }

    @Test func ignoresQueriesBelowTheSearchMinimum() {
        var recents = SearchRecents(["halo"])
        recents.remember("")
        recents.remember("a")
        #expect(recents.queries == ["halo"])
    }

    @Test func removeIsExactMatch() {
        var recents = SearchRecents(["Halo", "halo", "dune"])
        recents.remove("halo")
        #expect(recents.queries == ["Halo", "dune"])
    }

    @Test func clearEmptiesTheHistory() {
        var recents = SearchRecents(["halo", "dune"])
        recents.clear()
        #expect(recents.queries.isEmpty)
    }

    @Test func storeRoundTripsThroughTheClosures() {
        let memory = MemoryRecents(["halo"])
        memory.store.update { $0.remember("dune") }
        #expect(memory.queries == ["dune", "halo"])
        memory.store.update { $0.remove("halo") }
        #expect(memory.queries == ["dune"])
        memory.store.update { $0.clear() }
        #expect(memory.queries.isEmpty)
        #expect(memory.store.recents.queries.isEmpty)
    }

    @Test func preferencesStoreUsesTheRecentSearchesKey() {
        let saved = UserDefaults.standard.stringArray(forKey: "recentSearches")
        defer { UserDefaults.standard.set(saved, forKey: "recentSearches") }
        UserDefaults.standard.removeObject(forKey: "recentSearches")

        SearchRecentsStore.preferences.update { $0.remember("halo") }
        #expect(UserDefaults.standard.stringArray(forKey: "recentSearches") == ["halo"])
        #expect(SearchRecentsStore.preferences.recents.queries == ["halo"])
    }
}
