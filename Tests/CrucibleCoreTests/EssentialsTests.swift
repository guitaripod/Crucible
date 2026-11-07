import CryptoKit
import Foundation
import Testing
@testable import CrucibleCore

struct EssentialsTests {
    private static func seedBundle() throws -> GuideBundle {
        let data = try #require(GuideStore.bundledSeed())
        return try JSONDecoder().decode(GuideEnvelope.self, from: data).open(now: Date(timeIntervalSince1970: 1_794_000_000))
    }

    private static func dragonBallSuper() throws -> GuideShow {
        try #require(try seedBundle().show(matching: ExternalIDs(tvdb: 295068)))
    }

    /// Plex's view of a show filed as one season of 131, as arch's copy is.
    private static func library(_ guide: GuideShow, season: Int = 1) -> [PlexMetadata] {
        guide.episodes.map { e in
            PlexMetadata(
                ratingKey: "ep\(e.n)", key: nil, type: "episode", title: e.title, grandparentTitle: nil, grandparentRatingKey: "show",
                grandparentThumb: nil, grandparentArt: nil, parentTitle: nil, parentRatingKey: "s\(season)", parentThumb: nil,
                parentIndex: season, index: e.n, year: nil, summary: nil, tagline: nil, contentRating: nil, studio: nil, rating: nil,
                audienceRating: nil, duration: 1_389_000, viewOffset: nil, viewCount: nil, lastViewedAt: nil, viewedAt: nil, accountID: nil,
                deviceID: nil, addedAt: nil, originallyAvailableAt: e.aired, thumb: nil, art: nil, leafCount: nil, viewedLeafCount: nil,
                childCount: nil, librarySectionID: nil, librarySectionTitle: nil, Genre: nil, Role: nil, Director: nil, Writer: nil,
                Media: nil, Marker: nil, Chapter: nil, Related: nil
            )
        }
    }

    @Test func theSeedIsSignedAndCoversTheDragonBallShows() throws {
        let bundle = try Self.seedBundle()
        #expect(bundle.shows.map(\.slug).sorted() == ["dragon-ball", "dragon-ball-super", "dragon-ball-z"])
        let dbs = try Self.dragonBallSuper()
        #expect(dbs.episodes.count == 131)
        #expect(dbs.ranges.first?.from == 1 && dbs.ranges.first?.to == 27)
    }

    @Test func aTamperedOrForeignOrStaleEnvelopeIsRefused() throws {
        let data = try #require(GuideStore.bundledSeed())
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decode = { (object: [String: Any]) throws -> GuideEnvelope in
            try JSONDecoder().decode(GuideEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let original = try decode(json)
        #expect(throws: GuideEnvelope.Refusal.notNewer) { try original.open(now: now, after: original.sequence) }
        #expect(throws: GuideEnvelope.Refusal.expired) { try original.open(now: Date(timeIntervalSince1970: 1_900_000_000)) }
        json["sequence"] = original.sequence + 1
        #expect(throws: GuideEnvelope.Refusal.badSignature) { try decode(json).open(now: now) }
        json["sequence"] = original.sequence
        json["keyId"] = "someone-else"
        #expect(throws: GuideEnvelope.Refusal.unknownKey) { try decode(json).open(now: now) }
    }

    @Test func anEnvelopeSignedWithATrustedKeyOpens() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data(#"{"format":1,"generated":"x","licence":"l","shows":[]}"#.utf8)
        let signature = try key.signature(for: GuideEnvelope.message(format: 1, keyId: "t", sequence: 9, notAfter: "2030-01-01", payload: payload))
        let json: [String: Any] = ["format": 1, "keyId": "t", "sequence": 9, "notAfter": "2030-01-01", "payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()]
        let envelope = try JSONDecoder().decode(GuideEnvelope.self, from: JSONSerialization.data(withJSONObject: json))
        let bundle = try envelope.open(keys: ["t": key.publicKey.rawRepresentation.base64EncodedString()], now: Date(timeIntervalSince1970: 1_794_000_000))
        #expect(bundle.shows.isEmpty)
    }

    @Test func skipAnimeOnlyHidesTwentyOneEpisodesAndTheFilmsTwentySevenMore() throws {
        let guide = try Self.dragonBallSuper()
        let episodes = Self.library(guide)
        let plan = try #require(EssentialsPlan.make(guide: guide, episodes: episodes, choice: EssentialsChoice(level: .skipAnimeOnly)))
        #expect(plan.hiddenKeys.count == 21)
        #expect(plan.hides("ep42") && plan.hides("ep90"))
        #expect(!plan.hides("ep4"))
        let films = plan.with(EssentialsChoice(level: .skipAnimeOnly, seenRetold: true))
        #expect(films.shownCount == 83)
        let kept = plan.with(EssentialsChoice(level: .skipAnimeOnly, kept: [42]))
        #expect(!kept.hides("ep42") && kept.wouldHide("ep42"))
        #expect(plan.with(EssentialsChoice()).hiddenKeys.isEmpty)
        let preview = plan.preview(EssentialsChoice(level: .skipAnimeOnly))
        #expect(preview.hidden == 21)
        #expect(abs(preview.seconds - 21 * 1389) < 1)
    }

    @Test func upNextSkipsHiddenEpisodes() throws {
        let guide = try Self.dragonBallSuper()
        let episodes = Self.library(guide)
        let plan = try #require(EssentialsPlan.make(guide: guide, episodes: episodes, choice: EssentialsChoice(level: .skipAnimeOnly)))
        #expect(plan.next(after: "ep41", in: episodes)?.id == "ep47")
        #expect(plan.next(after: "ep67", in: episodes)?.id == "ep77")
        #expect(plan.next(after: "ep131", in: episodes) == nil)
        let upNext = ShowDetailModel.computeUpNext(in: episodes, hidden: plan.hiddenKeys)
        #expect(upNext?.episode.id == "ep1")
    }

    @Test func theSeasonHeaderCountsOnlyThatSeason() throws {
        let guide = try Self.dragonBallSuper()
        let episodes = Self.library(guide)
        let plan = try #require(EssentialsPlan.make(guide: guide, episodes: episodes, choice: EssentialsChoice(level: .skipAnimeOnly)))
        let arc = Array(episodes[27..<46])
        let hidden = arc.filter { plan.hides($0.id) }.count
        #expect(hidden > 0)
        let detail = try #require(EssentialsCopy.seasonDetail(plan, season: arc))
        #expect(detail.hasPrefix("\(19 - hidden) of 19 episodes · saves "))
        #expect(EssentialsCopy.seasonDetail(plan, season: Array(episodes[0..<14])) == nil)
    }

    @Test func aLibrarySplitIntoSeasonsStillLinesUp() throws {
        let guide = try Self.dragonBallSuper()
        let bounds = [14, 27, 46, 76, 131]
        let split = Self.library(guide).enumerated().map { index, episode -> PlexMetadata in
            let season = (bounds.firstIndex { index < $0 } ?? 4) + 1
            let start = season == 1 ? 0 : bounds[season - 2]
            return PlexMetadata(
                ratingKey: episode.id, key: nil, type: "episode", title: episode.title, grandparentTitle: nil, grandparentRatingKey: "show",
                grandparentThumb: nil, grandparentArt: nil, parentTitle: nil, parentRatingKey: "s\(season)", parentThumb: nil, parentIndex: season,
                index: index - start + 1, year: nil, summary: nil, tagline: nil, contentRating: nil, studio: nil, rating: nil, audienceRating: nil,
                duration: 1_389_000, viewOffset: nil, viewCount: nil, lastViewedAt: nil, viewedAt: nil, accountID: nil, deviceID: nil, addedAt: nil,
                originallyAvailableAt: episode.originallyAvailableAt, thumb: nil, art: nil, leafCount: nil, viewedLeafCount: nil, childCount: nil,
                librarySectionID: nil, librarySectionTitle: nil, Genre: nil, Role: nil, Director: nil, Writer: nil, Media: nil, Marker: nil,
                Chapter: nil, Related: nil
            )
        }
        let numbers = try #require(EpisodeAlignment.numbers(guide: guide, episodes: split))
        #expect(numbers["ep42"] == 42)
        #expect(numbers.count == 131)
    }

    @Test func episodesThatDoNotLineUpGiveNoPlan() throws {
        let guide = try Self.dragonBallSuper()
        let shuffled = Self.library(guide).map { episode in
            PlexMetadata(
                ratingKey: episode.id, key: nil, type: "episode", title: episode.title, grandparentTitle: nil, grandparentRatingKey: "show",
                grandparentThumb: nil, grandparentArt: nil, parentTitle: nil, parentRatingKey: "s1", parentThumb: nil, parentIndex: 1,
                index: episode.index, year: nil, summary: nil, tagline: nil, contentRating: nil, studio: nil, rating: nil, audienceRating: nil,
                duration: nil, viewOffset: nil, viewCount: nil, lastViewedAt: nil, viewedAt: nil, accountID: nil, deviceID: nil, addedAt: nil,
                originallyAvailableAt: "1999-01-01", thumb: nil, art: nil, leafCount: nil, viewedLeafCount: nil, childCount: nil,
                librarySectionID: nil, librarySectionTitle: nil, Genre: nil, Role: nil, Director: nil, Writer: nil, Media: nil, Marker: nil,
                Chapter: nil, Related: nil
            )
        }
        #expect(EpisodeAlignment.numbers(guide: guide, episodes: shuffled) == nil)
    }

    @Test func plexGuidsBecomeExternalIDs() {
        let ids = ExternalIDs(guids: ["imdb://tt4644488", "tmdb://62715", "tvdb://295068", "plex://show/5d9c"])
        #expect(ids == ExternalIDs(tvdb: 295068, tmdb: 62715, imdb: "tt4644488"))
        #expect(ExternalIDs(guids: []).isEmpty)
    }

    @Test func choicesAreKeptPerProfileAndShow() {
        let defaults = UserDefaults(suiteName: "essentials-tests-\(UUID().uuidString)")!
        let mine = EssentialsChoices(defaults: defaults, profile: "me")
        mine.save(EssentialsChoice(level: .skipAnimeOnly, kept: [42]), for: "dragon-ball-super")
        #expect(mine.choice(for: "dragon-ball-super").kept == [42])
        #expect(EssentialsChoices(defaults: defaults, profile: "kid").choice(for: "dragon-ball-super") == EssentialsChoice())
        EssentialsActiveShows.set("show", active: true, defaults: defaults, profile: "me")
        #expect(EssentialsActiveShows.contains("show", defaults: defaults, profile: "me"))
        #expect(!EssentialsActiveShows.contains("show", defaults: defaults, profile: "kid"))
    }

    @Test func theStorePrefersTheNewerOfTheSeedAndTheSavedBundle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = GuideStore(directory: directory, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let bundle = await store.bundle()
        #expect(bundle?.shows.count == 3)
        let empty = GuideStore(directory: directory, defaults: UserDefaults(suiteName: UUID().uuidString)!, seed: { nil })
        #expect(await empty.bundle() == nil)
    }
}
