@testable import CrucibleCore
import Foundation
import Testing
@testable import CrucibleDemo

/// The owner's tools work against the demo library, so the demo shows them doing something.
struct DemoManageTests {
    @Test func aLibraryScanShowsAsABackgroundTaskThatCanBeCancelled() async throws {
        try await withDemo { demo in
            let idle = try await LibraryManagement.activities(api: demo.api)
            #expect(idle.isEmpty)
            try await LibraryManagement.scan(sectionId: "1", force: false, api: demo.api)
            let running = try await LibraryManagement.activities(api: demo.api)
            let scan = try #require(running.first)
            #expect(running.count == 1)
            #expect(scan.cancellable == true)
            #expect(scan.title?.isEmpty == false)
            try await LibraryManagement.cancel(scan, api: demo.api)
            let afterCancel = try await LibraryManagement.activities(api: demo.api)
            #expect(afterCancel.isEmpty)
            try await LibraryManagement.analyze(sectionId: "1", api: demo.api)
            try await LibraryManagement.emptyTrash(sectionId: "1", api: demo.api)
        }
    }

    @Test func fixMatchOffersTheCurrentMatchFirstAndMatchingIsAccepted() async throws {
        try await withDemo { demo in
            let results = try await LibraryManagement.matches(ratingKey: "1008", title: "Lantern", year: 2001, api: demo.api)
            #expect(results.count == 3)
            #expect(results.first?.matched == true)
            #expect(results.dropFirst().contains { $0.name == "Lantern" && $0.year == 1990 })
            try await LibraryManagement.match(ratingKey: "1008", to: results[1], api: demo.api)
            try await LibraryManagement.unmatch(ratingKey: "1008", api: demo.api)
            try await LibraryManagement.refresh(ratingKey: "1008", api: demo.api)
            try await LibraryManagement.analyze(ratingKey: "1008", api: demo.api)
        }
    }

    @Test func editedDetailsShowOnTheTitle() async throws {
        try await withDemo { demo in
            let item = try await demo.metadata("1008")
            var edit = MetadataEdit(item: item, sectionId: "1")
            edit.title = "A New Name"
            edit.summary = "A summary the owner wrote."
            edit.year = "1999"
            try await LibraryManagement.edit(edit, api: demo.api)
            let edited = try await demo.metadata("1008")
            #expect(edited.title == "A New Name")
            #expect(edited.summary == "A summary the owner wrote.")
            #expect(edited.year == 1999)
        }
    }

    @Test func choosingAnotherPosterChangesTheTitlesPoster() async throws {
        try await withDemo { demo in
            let before = try await demo.metadata("1008")
            let choices = try await LibraryManagement.artwork(ratingKey: "1008", kind: .poster, api: demo.api)
            #expect(choices.count > 1)
            #expect(choices.first?.selected == true)
            #expect(choices.first?.imagePath == before.thumb)
            let other = try #require(choices.dropFirst().first)
            try await LibraryManagement.select(other, kind: .poster, ratingKey: "1008", api: demo.api)
            let chosen = try await demo.metadata("1008")
            #expect(chosen.thumb == other.imagePath)
            let backgrounds = try await LibraryManagement.artwork(ratingKey: "1008", kind: .background, api: demo.api)
            #expect(backgrounds.first?.imagePath == before.art)
        }
    }

    @Test func deletingIsRefusedTheWayAServerWithDeletionOffRefusesIt() async throws {
        try await withDemo { demo in
            await #expect(throws: (any Error).self) {
                try await LibraryManagement.delete(ratingKey: "1008", api: demo.api)
            }
            let kept = try await demo.metadata("1008")
            #expect(kept.id == "1008")
        }
    }

    @Test func aStoppedStreamLeavesTheSessions() async throws {
        try await withDemo { demo in
            let sessions = try await demo.api.requestContainer(.serverSessions).Metadata ?? []
            let ids = sessions.compactMap { $0.playbackSession?.id }
            #expect(ids.count == 2)
            let stopped = try #require(ids.first)
            try await LibraryManagement.stopStream(sessionId: stopped, reason: "Closing time", api: demo.api)
            await demo.api.invalidateCache()
            let after = (try await demo.api.requestContainer(.serverSessions).Metadata ?? []).compactMap { $0.playbackSession?.id }
            #expect(after == Array(ids.dropFirst()))
        }
    }

    @Test func aRemovedPlayLeavesTheWatchHistory() async throws {
        try await withDemo { demo in
            let before = try await demo.api.requestContainer(.history(start: 0, size: 20)).Metadata ?? []
            let removed = try #require(before.first)
            let key = try #require(removed.historyKey)
            try await LibraryManagement.deleteHistoryEntry(historyKey: key, api: demo.api)
            await demo.api.invalidateCache()
            let after = try await demo.api.requestContainer(.history(start: 0, size: 20)).Metadata ?? []
            #expect(!after.contains { $0.historyKey == key })
            #expect(after.first?.historyKey == before.dropFirst().first?.historyKey)
        }
    }

    @Test func aShowsServerSettingsCanBeChanged() async throws {
        try await withDemo { demo in
            let settings = try await ItemSettings.load(ratingKey: "2001", api: demo.api)
            let sort = try #require(settings.first { $0.id == "episodeSort" })
            #expect(sort.valueTitle == "Library default")
            try await ItemSettings.set(sort, to: "1", ratingKey: "2001", api: demo.api)
            let reloaded = try await ItemSettings.load(ratingKey: "2001", api: demo.api)
            #expect(reloaded.first { $0.id == "episodeSort" }?.valueTitle == "Newest first")
            let movie = try await ItemSettings.load(ratingKey: "1008", api: demo.api)
            #expect(movie.isEmpty)
        }
    }

    @Test func theDashboardHasLoadAndAnUpdateToOffer() async throws {
        try await withDemo { demo in
            let sample = try #require(try await LibraryManagement.load(api: demo.api))
            #expect((sample.processCpuUtilization ?? 0) > 0)
            let release = try #require(try await LibraryManagement.availableUpdate(api: demo.api))
            #expect(release.version?.isEmpty == false)
            #expect(release.added?.isEmpty == false)
            try await LibraryManagement.checkForUpdates(api: demo.api)
        }
    }
}
