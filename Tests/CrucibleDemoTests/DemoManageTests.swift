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

    @Test func fixMatchOffersTheCurrentMatchFirstAndTheMatchPickedRenamesTheTitle() async throws {
        try await withDemo { demo in
            let results = try await LibraryManagement.matches(ratingKey: "1008", title: "Lantern", year: 2001, api: demo.api)
            #expect(results.count == 3)
            #expect(results.first?.matched == true)
            #expect(results.dropFirst().contains { $0.name == "Lantern" && $0.year == 1990 })
            try await LibraryManagement.match(ratingKey: "1008", to: results[1], api: demo.api)
            let matched = try await demo.metadata("1008")
            #expect(matched.title == results[1].name)
            #expect(matched.year == results[1].year)
            #expect(matched.guid == results[1].guid)
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
            let background = try #require(backgrounds.dropFirst().first)
            try await LibraryManagement.select(background, kind: .background, ratingKey: "1008", api: demo.api)
            let backdrop = try await demo.metadata("1008")
            #expect(backdrop.art == background.imagePath)
            #expect(backdrop.art != before.art)
        }
    }

    @Test func deletingTakesAFilmOutOfTheLibraryForTheSession() async throws {
        try await withDemo { demo in
            let section = try await demo.api.requestContainer(.sectionItems(sectionId: "1", start: 0, size: 200)).Metadata ?? []
            #expect(section.contains { $0.ratingKey == "1008" })
            try await LibraryManagement.delete(ratingKey: "1008", api: demo.api)
            await demo.api.invalidateCache()
            await #expect(throws: (any Error).self) { _ = try await demo.metadata("1008") }
            let after = try await demo.api.requestContainer(.sectionItems(sectionId: "1", start: 0, size: 200)).Metadata ?? []
            #expect(after.count == section.count - 1)
            #expect(!after.contains { $0.ratingKey == "1008" })
        }
    }

    @Test func deletingAShowTakesItsSeasonsAndEpisodesWithIt() async throws {
        try await withDemo { demo in
            let show = try await demo.metadata("2001")
            let seasons = try await demo.api.requestContainer(.children(ratingKey: "2001")).Metadata ?? []
            let season = try #require(seasons.first?.ratingKey)
            let episodes = try await demo.api.requestContainer(.children(ratingKey: season)).Metadata ?? []
            let episode = try #require(episodes.first?.ratingKey)
            #expect(show.ratingKey == "2001")
            try await LibraryManagement.delete(ratingKey: "2001", api: demo.api)
            await demo.api.invalidateCache()
            for key in ["2001", season, episode] {
                await #expect(throws: (any Error).self) { _ = try await demo.metadata(key) }
            }
            let history = try await demo.api.requestContainer(.history(start: 0, size: 500)).Metadata ?? []
            #expect(!history.isEmpty)
            #expect(!history.contains { $0.grandparentTitle == show.title }, "the show's plays leave the watch history with it")
        }
    }

    @Test func deletingAFilmTakesItsExtrasWithIt() async throws {
        try await withDemo { demo in
            #expect(try await demo.metadata("8101").ratingKey == "8101")
            try await LibraryManagement.delete(ratingKey: "1001", api: demo.api)
            await demo.api.invalidateCache()
            await #expect(throws: (any Error).self) { _ = try await demo.metadata("8101") }
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
            try await LibraryManagement.installUpdate(api: demo.api)
            await demo.api.invalidateCache()
            #expect(try await LibraryManagement.availableUpdate(api: demo.api) == nil)
        }
    }
}
