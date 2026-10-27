import Foundation
import Testing
@testable import CrucibleCore

struct AuthTopShelfTests {
    private let source = TopShelfBuilder.Source(serverURL: URL(string: "http://192.168.1.5:32400/")!, token: "tok", machineIdentifier: "m1")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func episode(_ key: String, offset: Int? = nil, section: Int = 1) -> PlexMetadata {
        let offsetJSON = offset.map { #""viewOffset": \#($0),"# } ?? ""
        return AuthFixtures.metadata("""
        {"ratingKey": "\(key)", "type": "episode", "title": "Low Tide", "grandparentTitle": "The Show", "parentIndex": 2, "index": 4,
         \(offsetJSON) "duration": 2700000, "summary": "A body on the rocks.", "thumb": "/library/metadata/\(key)/thumb/1", "art": "/library/metadata/\(key)/art/1",
         "grandparentArt": "/library/metadata/100/art/1", "librarySectionID": \(section)}
        """)
    }

    private func movie(_ key: String, offset: Int? = nil, section: Int = 1) -> PlexMetadata {
        let offsetJSON = offset.map { #""viewOffset": \#($0),"# } ?? ""
        return AuthFixtures.metadata("""
        {"ratingKey": "\(key)", "type": "movie", "title": "Salt and Rope", \(offsetJSON) "duration": 7200000,
         "summary": "A heist gone wrong.", "thumb": "/library/metadata/\(key)/thumb/1", "art": "/library/metadata/\(key)/art/1", "librarySectionID": \(section)}
        """)
    }

    private func build(continueItems: [PlexMetadata], onDeck: [PlexMetadata], excluded: Set<Int> = []) -> TopShelfSnapshot {
        TopShelfBuilder.snapshot(buckets: HomeBuckets(continueWatching: continueItems, onDeck: onDeck), source: source, excludedLibraries: excluded, now: now)
    }

    @Test func continueWatchingAndUpNextBecomeTwoSections() {
        let snapshot = build(continueItems: [episode("11", offset: 600_000)], onDeck: [movie("21")])

        #expect(snapshot.schema == TopShelfSnapshot.schemaVersion)
        #expect(snapshot.machineIdentifier == "m1")
        #expect(snapshot.savedAt == 1_700_000_000)
        #expect(snapshot.sections.map(\.title) == ["Continue Watching", "Up Next"])
        let first = snapshot.sections[0].items[0]
        #expect(first.ratingKey == "11")
        #expect(first.type == "episode")
        #expect(first.title == "Low Tide")
        #expect(first.subtitle == "The Show · S2 · E4")
        #expect(first.summary == "A body on the rocks.")
        #expect(snapshot.sections[1].items[0].subtitle == "Up Next")
    }

    @Test func progressIsTheWatchedFractionAndAbsentWhenNothingWasWatched() throws {
        let snapshot = build(continueItems: [episode("11", offset: 1_350_000), movie("12")], onDeck: [])
        #expect(try #require(snapshot.sections[0].items[0].progress) == 0.5)
        #expect(snapshot.sections[0].items[1].progress == nil)
    }

    @Test func upNextNeverRepeatsContinueWatchingOrItself() {
        let snapshot = build(continueItems: [episode("11", offset: 1000), episode("11", offset: 1000)], onDeck: [episode("11"), movie("21"), movie("21")])

        #expect(snapshot.sections[0].items.map(\.ratingKey) == ["11"])
        #expect(snapshot.sections[1].items.map(\.ratingKey) == ["21"])
    }

    @Test func eachSectionIsCappedAtTwelveItems() {
        let many = (1...20).map { movie("\($0)") }
        let snapshot = build(continueItems: many, onDeck: many.map { movie("9\($0.id)") })

        #expect(snapshot.sections.map(\.items.count) == [12, 12])
        #expect(snapshot.sections[0].items.first?.ratingKey == "1")
    }

    @Test func librariesLeftOutOfHomeStayOffTheTopShelf() {
        let snapshot = build(continueItems: [movie("1", section: 7), movie("2", section: 3)], onDeck: [movie("3", section: 7)], excluded: [7])

        #expect(snapshot.sections.map(\.title) == ["Continue Watching"])
        #expect(snapshot.sections[0].items.map(\.ratingKey) == ["2"])
    }

    @Test func nothingToShowYieldsAnEmptySnapshot() {
        let snapshot = build(continueItems: [], onDeck: [])
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.isEmpty)
    }

    @Test func artworkIsALandscapeStillForEpisodesAndABackdropForMovies() {
        #expect(TopShelfBuilder.imagePath(for: episode("11")) == "/library/metadata/11/thumb/1")
        #expect(TopShelfBuilder.imagePath(for: movie("12")) == "/library/metadata/12/art/1")
        let bare = AuthFixtures.metadata(#"{"ratingKey": "13", "type": "movie", "title": "Bare", "thumb": "/t"}"#)
        #expect(TopShelfBuilder.imagePath(for: bare) == "/t")
        let noArt = AuthFixtures.metadata(#"{"ratingKey": "14", "type": "movie", "title": "None"}"#)
        #expect(TopShelfBuilder.imagePath(for: noArt) == nil)
    }

    @Test func imageURLsGoThroughThePhotoTranscoderWithTheToken() throws {
        let url = try #require(TopShelfBuilder.imageURL(path: "/library/metadata/12/art/1", source: source))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "http")
        #expect(components.host == "192.168.1.5")
        #expect(components.port == 32400)
        #expect(components.path == "/photo/:/transcode")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["url"] == "/library/metadata/12/art/1")
        #expect(query["width"] == "1920")
        #expect(query["height"] == "1080")
        #expect(query["X-Plex-Token"] == "tok")

        let large = try #require(TopShelfBuilder.imageURL(path: "/library/metadata/12/art/1", width: TopShelfBuilder.image2xWidth, height: TopShelfBuilder.image2xHeight, source: source))
        let largeQuery = Dictionary(uniqueKeysWithValues: (URLComponents(url: large, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(largeQuery["width"] == "3840")
        #expect(largeQuery["height"] == "2160")
    }

    @Test func eachItemCarriesBothImageScales() {
        let snapshot = build(continueItems: [episode("11")], onDeck: [])
        let item = snapshot.sections[0].items[0]
        let one = URLComponents(url: item.imageURL!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "width" }?.value
        let two = URLComponents(url: item.image2xURL!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "width" }?.value
        #expect(one == "1920")
        #expect(two == "3840")
    }

    @Test func itemsWithoutArtworkStillAppear() {
        let bare = AuthFixtures.metadata(#"{"ratingKey": "14", "type": "movie", "title": "None"}"#)
        let snapshot = build(continueItems: [bare], onDeck: [])
        #expect(snapshot.sections[0].items[0].imageURL == nil)
    }

    @Test func snapshotsRoundTripThroughJSON() throws {
        let snapshot = build(continueItems: [episode("11", offset: 600_000)], onDeck: [movie("21")])
        let decoded = try JSONDecoder().decode(TopShelfSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func deepLinksRoundTripThroughTheirURL() {
        let play = DeepLink.play(ratingKey: "42")
        #expect(play.url.absoluteString == "crucible://play/42")
        #expect(DeepLink(url: play.url) == play)

        let item = DeepLink.item(ratingKey: "42", mediaType: "episode")
        #expect(item.url.absoluteString == "crucible://item/42?type=episode")
        #expect(DeepLink(url: item.url) == item)
        #expect(DeepLink.item(ratingKey: "42", mediaType: nil).url.absoluteString == "crucible://item/42")
    }

    @Test func thePlanMapsCarouselCardsAndActions() throws {
        let show = AuthFixtures.metadata(#"{"ratingKey": "30", "type": "show", "title": "A Show"}"#)
        let snapshot = build(continueItems: [episode("11", offset: 600_000)], onDeck: [show])
        let plan = try #require(TopShelfPlan(snapshot: snapshot))

        #expect(plan.items.map(\.identifier) == ["11", "30"])
        let resume = plan.items[0]
        #expect(resume.title == "Low Tide")
        #expect(resume.contextTitle == "The Show · S2 · E4")
        #expect(resume.summary == "A body on the rocks.")
        #expect(resume.imageURL != nil)
        #expect(resume.image2xURL != nil)
        #expect(resume.playURL?.absoluteString == "crucible://play/11")
        #expect(resume.displayURL.absoluteString == "crucible://item/11?type=episode")

        let browse = plan.items[1]
        #expect(browse.contextTitle == "Up Next")
        #expect(browse.playURL == nil)
        #expect(browse.displayURL.absoluteString == "crucible://item/30?type=show")
    }

    @Test func thePlanKeepsAtMostTenCards() throws {
        let many = (1...20).map { movie("\($0)") }
        let plan = try #require(TopShelfPlan(snapshot: build(continueItems: many, onDeck: [])))
        #expect(plan.items.count == TopShelfPlan.maxItems)
        #expect(plan.items.first?.identifier == "1")
    }

    @Test func tilesOfOtherTypesOpenTheirDetailWithoutAType() throws {
        let clip = AuthFixtures.metadata(#"{"ratingKey": "31", "type": "clip", "title": "A Clip"}"#)
        let plan = try #require(TopShelfPlan(snapshot: build(continueItems: [clip], onDeck: [])))
        let tile = plan.items[0]
        #expect(tile.playURL?.absoluteString == "crucible://play/31")
        #expect(tile.displayURL.absoluteString == "crucible://item/31")
        #expect(DeepLink(url: tile.displayURL) == .item(ratingKey: "31", mediaType: nil))
    }

    @Test func thePlanIsNilWhenThereIsNothingToShow() {
        #expect(TopShelfPlan(snapshot: nil) == nil)
        #expect(TopShelfPlan(snapshot: build(continueItems: [], onDeck: [])) == nil)
        let stale = TopShelfSnapshot(schema: 99, machineIdentifier: "m1", savedAt: 0, sections: [TopShelfSection(title: "x", items: [TopShelfItem(ratingKey: "1", type: "movie", title: "t", subtitle: nil, imageURL: nil, progress: nil)])])
        #expect(TopShelfPlan(snapshot: stale) == nil)
    }

    private func temporaryStore() -> (TopShelfStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-\(UUID().uuidString)")
        return (TopShelfStore(directory: directory), directory)
    }

    @Test func theStoreSavesLoadsAndClears() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = build(continueItems: [movie("1", offset: 1000)], onDeck: [])

        #expect(store.load() == nil)
        #expect(store.save(snapshot))
        #expect(store.load() == snapshot)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func theSnapshotGoesIntoLibraryCaches() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = build(continueItems: [movie("1")], onDeck: [])

        #expect(store.save(snapshot))
        let caches = directory.appendingPathComponent("Library/Caches/topshelf.json")
        #expect(FileManager.default.fileExists(atPath: caches.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("topshelf.json").path))
        #expect(store.existingSnapshotPath == caches.path)
    }

    @Test func aSnapshotWrittenAtTheContainerRootIsStillReadAndReplaced() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = build(continueItems: [movie("1")], onDeck: [])
        let root = directory.appendingPathComponent("topshelf.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: root)

        #expect(store.load() == legacy)

        let fresh = build(continueItems: [movie("2")], onDeck: [])
        #expect(store.save(fresh))
        #expect(store.load() == fresh)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func theExtensionReceiptRoundTrips() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.receipt() == nil)

        let receipt = TopShelfReceipt(readAt: 1_700_000_000, itemCount: 7, imageCount: 6, snapshotSchema: 2)
        #expect(store.saveReceipt(receipt))
        #expect(store.receipt() == receipt)
    }

    @Test func diagnosticsExplainAnEmptyStore() {
        let store = TopShelfStore(directory: nil)
        let diagnostics = store.diagnostics
        #expect(diagnostics.snapshotSummary == "No App Group")
        #expect(diagnostics.snapshot == nil)
        #expect(!diagnostics.hasContainer)
    }

    @Test func theStoreRejectsOversizedAndForeignSnapshots() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("topshelf.json")

        try Data(count: TopShelfStore.maxReadBytes + 1).write(to: file)
        #expect(store.load() == nil)

        try Data(#"{"schema": 99, "machineIdentifier": "m", "savedAt": 0, "sections": []}"#.utf8).write(to: file)
        #expect(store.load() == nil)

        try Data("not json".utf8).write(to: file)
        #expect(store.load() == nil)
    }

    @Test func aStoreWithoutAContainerNeitherSavesNorLoads() {
        let store = TopShelfStore(directory: nil)
        #expect(!store.save(build(continueItems: [movie("1")], onDeck: [])))
        #expect(store.load() == nil)
    }

    @Test func theUpdaterWritesChangesOnlyAndAnnouncesThem() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let announcements = AuthLocked(0)
        let notify: @Sendable () -> Void = { announcements.update { $0 += 1 } }

        let first = build(continueItems: [movie("1", offset: 1000)], onDeck: [])
        #expect(TopShelfUpdater.write(first, to: store, notify: notify))
        #expect(announcements.value == 1)

        let later = TopShelfSnapshot(machineIdentifier: first.machineIdentifier, savedAt: first.savedAt + 600, sections: first.sections)
        #expect(!TopShelfUpdater.write(later, to: store, notify: notify))
        #expect(announcements.value == 1)

        let changed = build(continueItems: [movie("1", offset: 2000)], onDeck: [])
        #expect(TopShelfUpdater.write(changed, to: store, notify: notify))
        #expect(announcements.value == 2)
        #expect(store.load() == changed)
    }

    @Test func anEmptyRefreshRemovesAStaleSnapshotAndAnnouncesIt() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let announcements = AuthLocked(0)
        let notify: @Sendable () -> Void = { announcements.update { $0 += 1 } }
        let empty = build(continueItems: [], onDeck: [])

        #expect(!TopShelfUpdater.write(empty, to: store, notify: notify))
        #expect(announcements.value == 0)

        store.save(build(continueItems: [movie("1")], onDeck: []))
        #expect(TopShelfUpdater.write(empty, to: store, notify: notify))
        #expect(store.load() == nil)
        #expect(announcements.value == 1)
    }

    @MainActor
    @Test func clearingOnSignOutAnnouncesOnlyWhenThereWasSomethingToClear() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let announcements = AuthLocked(0)
        let notify: @Sendable () -> Void = { announcements.update { $0 += 1 } }

        TopShelfUpdater.clear(store: store, notify: notify)
        #expect(announcements.value == 0)

        store.save(build(continueItems: [movie("1")], onDeck: []))
        TopShelfUpdater.clear(store: store, notify: notify)
        #expect(store.load() == nil)
        #expect(announcements.value == 1)
    }
}
