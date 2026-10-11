import Foundation
import Testing
@testable import CrucibleCore

struct DetailFormatTests {
    @Test(arguments: [
        (0.0, nil),
        (-5.0, nil),
        (Double.nan, nil),
        (20.0, "1 min"),
        (2520.0, "42 min"),
        (7200.0, "2 h"),
        (8040.0, "2 h 14 m"),
        (3599.0, "1 h"),
    ] as [(Double, String?)])
    func runtimeVocabulary(seconds: Double, expected: String?) {
        #expect(DetailFormat.runtime(seconds) == expected)
    }

    @Test func remainingNeedsPositionInsideDuration() {
        #expect(DetailFormat.remaining(position: 600, duration: 2700) == "35 min left")
        #expect(DetailFormat.remaining(position: 0, duration: 2700) == nil)
        #expect(DetailFormat.remaining(position: 2700, duration: 2700) == nil)
        #expect(DetailFormat.remaining(position: 100, duration: 0) == nil)
    }

    @Test func spokenDurationClampsToAMinuteAndNamesHours() throws {
        #expect(DetailFormat.spokenDuration(0) == nil)
        #expect(DetailFormat.spokenDuration(10) == DetailFormat.spokenDuration(60))
        let long = try #require(DetailFormat.spokenDuration(8040))
        #expect(long.contains("hour"))
        #expect(long.contains("minute"))
    }

    @Test func episodeCodeNeedsAnEpisodeNumber() {
        #expect(DetailFormat.episodeCode(season: 2, episode: 4) == "S2 · E4")
        #expect(DetailFormat.episodeCode(season: nil, episode: 4) == "E4")
        #expect(DetailFormat.episodeCode(season: 2, episode: nil) == nil)
        #expect(DetailFormat.episodeCode(season: nil, episode: nil) == nil)
    }

    @Test func ratingPartsPreferAudienceAndAddCriticPercent() {
        let both = DetailFormat.ratingParts(audience: 8.14, critic: 9.2)
        #expect(both.star == "8.1")
        #expect(both.trailing == ["92% critics"])
        let criticOnly = DetailFormat.ratingParts(audience: 0, critic: 7.5)
        #expect(criticOnly.star == "7.5")
        #expect(criticOnly.trailing.isEmpty)
        let none = DetailFormat.ratingParts(audience: nil, critic: 0)
        #expect(none.star == nil)
        #expect(none.trailing.isEmpty)
    }

    @Test func spokenRatingFallsBackToCritic() {
        #expect(DetailFormat.spokenRating(audience: 8.1, critic: 5) == "rated 8.1 out of 10")
        #expect(DetailFormat.spokenRating(audience: 0, critic: 6.5) == "rated 6.5 out of 10")
        #expect(DetailFormat.spokenRating(audience: nil, critic: nil) == nil)
    }

    @Test func technicalBadgesListResolutionRangeAudioChannelsAndRating() {
        let item = DetailFixtures.item(["Media": DetailFixtures.richMedia])
        let audio = DetailFormat.primaryAudioStream(item)
        #expect(DetailFormat.technicalBadges(for: item, contentRating: "TV-MA", audio: audio) == ["4K", "HDR10", "DD+", "5.1", "TV-MA"])
        #expect(DetailFormat.technicalBadges(for: nil, contentRating: "PG", audio: nil) == ["PG"])
        #expect(DetailFormat.technicalBadges(for: nil, contentRating: "", audio: nil).isEmpty)
    }

    @Test func atmosReplacesTheAudioCodecBadge() {
        let media: [[String: Any]] = [[
            "height": 1080,
            "Part": [["id": 1, "key": "/p", "Stream": [
                ["id": 1, "streamType": 2, "codec": "truehd", "channels": 8, "displayTitle": "English (TrueHD 7.1 Atmos)", "selected": true],
            ]]],
        ]]
        let item = DetailFixtures.item(["Media": media])
        let audio = DetailFormat.primaryAudioStream(item)
        #expect(DetailFormat.technicalBadges(for: item, contentRating: nil, audio: audio) == ["1080p", "DOLBY ATMOS", "7.1"])
    }

    @Test func dolbyVisionBeatsHdr() {
        func range(_ title: String) -> String? {
            let media: [[String: Any]] = [[
                "Part": [["id": 1, "key": "/p", "Stream": [["id": 1, "streamType": 1, "displayTitle": title]]]],
            ]]
            return DetailFormat.technicalBadges(for: DetailFixtures.item(["Media": media]), contentRating: nil, audio: nil).first
        }
        #expect(range("4K DoVi HDR10") == "DOLBY VISION")
        #expect(range("HDR10+ stream") == "HDR10+")
        #expect(range("HLG") == "HDR")
        #expect(range("SDR") == nil)
    }

    @Test func primaryAudioPrefersSelectionThenSelectedThenDefault() throws {
        let item = DetailFixtures.item(["Media": DetailFixtures.richMedia])
        #expect(DetailFormat.primaryAudioStream(item)?.id == 11)
        #expect(DetailFormat.primaryAudioStream(item, selectedId: 12)?.id == 12)
        #expect(DetailFormat.primaryAudioStream(item, selectedId: 999)?.id == 11)
    }

    @Test func trackLabels() throws {
        let item = DetailFixtures.item(["Media": DetailFixtures.richMedia])
        let english = try #require(item.audioStreams.first)
        #expect(DetailFormat.languageName(english) == "English")
        #expect(DetailFormat.audioValue(english) == "English · 5.1")
        #expect(DetailFormat.audioDetail(english) == "DD+ · 5.1 · 640 kbps")
        let subtitles = item.subtitleStreams
        #expect(DetailFormat.subtitleValue(subtitles[0]) == "English")
        #expect(DetailFormat.subtitleDetail(subtitles[0]) == "SRT · Default")
        #expect(DetailFormat.subtitleDetail(subtitles[1]) == "Image-based")
    }

    @Test func fileAndAudioFacts() {
        let item = DetailFixtures.item(["Media": DetailFixtures.richMedia])
        #expect(DetailFormat.fileFact(item) == "HEVC · MKV · 4.0 GB")
        #expect(DetailFormat.audioFact(DetailFormat.primaryAudioStream(item)) == "DD+ 5.1 · English")
        #expect(DetailFormat.audioFact(nil) == nil)
        #expect(DetailFormat.fileFact(DetailFixtures.item()) == nil)
    }

    @Test func addedDateIgnoresMissingTimestamps() {
        #expect(DetailFormat.addedDate(nil) == nil)
        #expect(DetailFormat.addedDate(0) == nil)
        #expect(DetailFormat.addedDate(1_700_000_000) != nil)
    }

    @Test(arguments: [
        ("Keanu Reeves", "KR"),
        ("Cher", "C"),
        ("Jean-Luc Picard", "JP"),
        ("  ", ""),
        ("", ""),
        ("mary jane watson", "MW"),
    ])
    func initials(name: String, expected: String) {
        #expect(DetailFormat.initials(name) == expected)
    }
}
