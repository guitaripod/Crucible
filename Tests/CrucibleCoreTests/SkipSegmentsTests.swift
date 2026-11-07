import Foundation
import Testing
@testable import CrucibleCore

struct SkipSegmentsTests {
    private static func chapters(_ list: [(String, Double, Double)]) -> [PlexChapter] {
        list.enumerated().map { index, entry in
            PlexChapter(index: index + 1, tag: entry.0, startTimeOffset: Int(entry.1 * 1000), endTimeOffset: Int(entry.2 * 1000), thumb: nil)
        }
    }

    private static let dragonBallSuper = chapters([
        ("Opening Theme", 0, 85.088), ("Recap", 85.088, 134.723), ("Part A", 134.723, 729.176),
        ("Part B", 729.176, 1295.182), ("Ending Theme", 1295.182, 1355.245), ("Next Episode Preview", 1355.245, 1386.239),
    ])

    @Test func anAnimeEpisodesNamedChaptersBecomeFourSegments() {
        let segments = SkipSegments.make(markers: [], chapters: Self.dragonBallSuper, durationSecs: 1386.239)
        #expect(segments.map(\.kind) == [.intro, .recap, .ending, .preview])
        #expect(segments.filter { !$0.fromChapter }.isEmpty)
        #expect(segments[1].startSecs == 85.088)
    }

    @Test func otherShowsNamingSchemesAreRead() {
        #expect(SkipSegments.kind(forTitle: "Previously On") == .recap)
        #expect(SkipSegments.kind(forTitle: "Opening Credits") == .intro)
        #expect(SkipSegments.kind(forTitle: "End Credits") == .credits)
        #expect(SkipSegments.kind(forTitle: "  OP ") == .intro)
        #expect(SkipSegments.kind(forTitle: "ED2") == .ending)
        #expect(SkipSegments.kind(forTitle: "Final Ending Theme") == .ending)
        #expect(SkipSegments.kind(forTitle: "次回予告") == .preview)
        #expect(SkipSegments.kind(forTitle: "Chapter 01") == nil)
        #expect(SkipSegments.kind(forTitle: "Recap of the War") == nil)
        #expect(SkipSegments.kind(forTitle: "Part A") == nil)
    }

    @Test func aChapterOutOfPlaceIsIgnored() {
        let mislabelled = Self.chapters([("Part A", 0, 1200), ("Recap", 1200, 1260), ("Part B", 1260, 1380)])
        #expect(SkipSegments.make(markers: [], chapters: mislabelled, durationSecs: 1386).isEmpty)
        let longIntro = Self.chapters([("Opening", 0, 900), ("Episode", 900, 1400)])
        #expect(SkipSegments.make(markers: [], chapters: longIntro, durationSecs: 1400).isEmpty)
    }

    @Test func plexMarkersWinOverChaptersOfTheSameKind() {
        let intro = PlexMarker(type: "intro", startTimeOffset: 2_000, endTimeOffset: 84_000, final: nil)
        let credits = PlexMarker(type: "credits", startTimeOffset: 1_296_000, endTimeOffset: 1_355_000, final: nil)
        let segments = SkipSegments.make(markers: [intro, credits], chapters: Self.dragonBallSuper, durationSecs: 1386.239)
        #expect(segments.map(\.kind) == [.intro, .recap, .credits, .preview])
        #expect(segments[0].fromChapter == false)
        #expect(segments[0].startSecs == 2)
        #expect(segments[2].fromChapter == false)
    }

    @Test func theChaptersOwnEndStandsInForAnUnknownDuration() {
        let segments = SkipSegments.make(markers: [], chapters: Self.dragonBallSuper, durationSecs: 0)
        #expect(segments.count == 4)
        #expect(SkipSegments.make(markers: [], chapters: [], durationSecs: 0).isEmpty)
    }
}
