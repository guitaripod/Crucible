import Foundation
import Testing

@testable import CrucibleCore

@Suite("Intro markers on the picture's edges")
struct MarkerSnapTests {
    private static let crimeAid = SkipMarker(kind: .intro, startSecs: 134.570, endSecs: 157.935)

    @Test func movesTheOfficesIntroOntoTheCutIntoTheTitlesAndTheBlackAfterThem() {
        let start = MarkerSnap.Edges(cuts: [137.554])
        let end = MarkerSnap.Edges(cuts: [158.283], blackEnds: [158.283])
        let refined = MarkerSnap.refined(Self.crimeAid, start: start, end: end)
        #expect(refined.startSecs == 137.554)
        #expect(refined.endSecs == 158.283)
    }

    @Test func leavesAStartThatSitsOnACutAndAnEndWithNoEdgeNearIt() {
        let refined = MarkerSnap.refined(Self.crimeAid, start: .init(cuts: [134.7, 137.5]), end: .init(cuts: [170]))
        #expect(refined == Self.crimeAid)
    }

    @Test func neverMovesFurtherThanItsWindowsOrTouchesOtherKinds() {
        let far = MarkerSnap.refined(Self.crimeAid, start: .init(cuts: [140]), end: .init(blackEnds: [163]))
        #expect(far == Self.crimeAid)
        let credits = SkipMarker(kind: .credits, startSecs: 100, endSecs: 200)
        #expect(MarkerSnap.refined(credits, start: .init(cuts: [101]), end: .init(blackEnds: [201])) == credits)
    }

    @Test func readsWhatFFmpegPrintsOnTheItemsTimeline() {
        let output = """
        [scdet @ 0x1] lavfi.scd.score: 31.2, lavfi.scd.time: 4.556
        [blackdetect @ 0x2] black_start:4.431 black_end:4.556 black_duration:0.125
        """
        let edges = MarkerSnap.edges(fromFFmpeg: output, offset: 136.251)
        #expect(edges.cuts.count == 1 && abs(edges.cuts[0] - 140.807) < 0.0001)
        #expect(edges.blackEnds.count == 1 && abs(edges.blackEnds[0] - 140.807) < 0.0001)
    }
}
