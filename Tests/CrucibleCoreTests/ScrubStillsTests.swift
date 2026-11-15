@testable import CrucibleCore
import Foundation
import Testing

struct ScrubStillsTests {
    private func media(indexes: String?) throws -> PlexMedia {
        let indexes = indexes.map { #", "indexes": "\#($0)""# } ?? ""
        let json = #"{"id": 7, "Part": [{"id": 42, "key": "/library/parts/42/file.mkv"\#(indexes)}]}"#
        return try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
    }

    @Test func aPartWithStillsIsFoundAndOneWithoutIsNot() throws {
        #expect(ScrubStills.part(of: try media(indexes: "sd"))?.id == 42)
        #expect(ScrubStills.part(of: try media(indexes: nil)) == nil)
        #expect(ScrubStills.part(of: nil) == nil)
    }

    @Test func aStillIsAskedForToTheSecondInMilliseconds() {
        #expect(ScrubStills.second(61.4) == 61)
        #expect(ScrubStills.second(61.6) == 62)
        #expect(ScrubStills.second(-3) == 0)
        #expect(ScrubStills.second(.nan) == 0)
        #expect(ScrubStills.path(partID: 42, second: 62) == "/library/parts/42/indexes/sd/62000")
    }

    @Test func onlyOneRequestRunsAndTheNewestTargetFollowsIt() {
        var queue = ScrubStillQueue()
        #expect(queue.want(10, held: false) == 10)
        #expect(queue.want(11, held: false) == nil)
        #expect(queue.want(12, held: false) == nil)
        #expect(queue.inFlight == 10)
        #expect(queue.landed(true) == 12)
        #expect(queue.landed(true) == nil)
        #expect(queue.inFlight == nil)
    }

    @Test func aTargetThatLandedIsNotAskedForAgain() {
        var queue = ScrubStillQueue()
        #expect(queue.want(10, held: false) == 10)
        #expect(queue.want(10, held: false) == nil)
        #expect(queue.landed(true) == nil)
    }

    @Test func aHeldStillAsksNothingAndCancelsTheWaitingTarget() {
        var queue = ScrubStillQueue()
        #expect(queue.want(10, held: false) == 10)
        #expect(queue.want(20, held: false) == nil)
        #expect(queue.want(5, held: true) == nil)
        #expect(queue.landed(true) == nil)
    }

    @Test func aFirstMissMeansTheFileHasNoStills() {
        var queue = ScrubStillQueue()
        #expect(queue.want(10, held: false) == 10)
        #expect(queue.want(20, held: false) == nil)
        #expect(queue.landed(false) == nil)
        #expect(queue.isUnavailable)
        #expect(queue.want(30, held: false) == nil)
    }

    @Test func aMissAfterAStillArrivedKeepsAsking() {
        var queue = ScrubStillQueue()
        #expect(queue.want(10, held: false) == 10)
        #expect(queue.landed(true) == nil)
        #expect(queue.want(20, held: false) == 20)
        #expect(queue.want(25, held: false) == nil)
        #expect(queue.landed(false) == 25)
        #expect(!queue.isUnavailable)
    }

    @Test func theNearestHeldStillStandsInWithinReach() {
        #expect(ScrubStillQueue.standIn(for: 100, among: [10, 90, 104, 300]) == 104)
        #expect(ScrubStillQueue.standIn(for: 100, among: [10, 300]) == nil)
        #expect(ScrubStillQueue.standIn(for: 100, among: [Int]()) == nil)
    }
}
