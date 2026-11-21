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

    private func bif(stamps: [UInt32], unit: UInt32, stills: [[UInt8]]) -> Data {
        var bytes: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
        func word(_ value: UInt32) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)] }
        word(0)
        word(UInt32(stamps.count))
        word(unit)
        bytes += [UInt8](repeating: 0, count: 44)
        var offset = UInt32(64 + (stamps.count + 1) * 8)
        for (stamp, still) in zip(stamps, stills) {
            word(stamp)
            word(offset)
            offset += UInt32(still.count)
        }
        word(0xFFFF_FFFF)
        word(offset)
        stills.forEach { bytes += $0 }
        return Data(bytes)
    }

    @Test func aBIFIndexReadsEveryStillWithItsTimeAndBytes() throws {
        let data = bif(stamps: [0, 1, 2], unit: 2000, stills: [[1, 2], [3, 4, 5], [6]])
        let index = try #require(BIFIndex(data))
        #expect(index.frames.map(\.seconds) == [0, 2, 4])
        #expect(index.frames.map { [UInt8](data[$0.bytes]) } == [[1, 2], [3, 4, 5], [6]])
    }

    @Test func aBIFIndexFindsTheStillShowingAMoment() throws {
        let index = try #require(BIFIndex(bif(stamps: [0, 1, 2, 3], unit: 0, stills: [[1], [2], [3], [4]])))
        #expect(index.frame(at: -5) == 0)
        #expect(index.frame(at: 0.5) == 0)
        #expect(index.frame(at: 1) == 1)
        #expect(index.frame(at: 2.9) == 2)
        #expect(index.frame(at: 99) == 3)
    }

    @Test func somethingElseIsNotABIFIndex() {
        #expect(BIFIndex(Data("<html>not found</html>".utf8)) == nil)
        var truncated = [UInt8](bif(stamps: [0, 1], unit: 1000, stills: [[1, 2, 3], [4, 5, 6]]))
        truncated.removeLast(4)
        #expect(BIFIndex(Data(truncated)) == nil)
    }

    @Test func theHeaderAndTableAloneGiveTheWholeIndex() throws {
        let data = bif(stamps: [0, 1, 2], unit: 2000, stills: [[1, 2], [3, 4, 5], [6]])
        let length = try #require(BIFIndex.tableLength(header: data.prefix(BIFIndex.headerSize)))
        #expect(length == 64 + 4 * 8)
        let index = try #require(BIFIndex(table: data.prefix(length)))
        #expect(index == BIFIndex(data))
        #expect(index.length == data.count)
        #expect(BIFIndex(table: data.prefix(length - 1)) == nil)
        #expect(BIFIndex.tableLength(header: Data(repeating: 0, count: 64)) == nil)
        #expect(BIFIndex.tableLength(header: data.prefix(20)) == nil)
    }

    @Test func aTableWhoseStillsRunBackwardsIsRefused() {
        var bytes = [UInt8](bif(stamps: [0, 1], unit: 1000, stills: [[1, 2, 3], [4, 5, 6]]))
        bytes[64 + 12] = 64 + 24
        #expect(BIFIndex(Data(bytes)) == nil)
    }

    @Test func stillsTravelInSpansFetchedOutwardFromWhereTheScrubberIs() throws {
        let stills = (0..<10).map { [UInt8](repeating: UInt8($0), count: $0 + 1) }
        let data = bif(stamps: Array(0..<10), unit: 1000, stills: stills)
        let index = try #require(BIFIndex(data))
        #expect(index.interval == 1)
        #expect(index.spanCount(size: 4) == 3)
        let middle = try #require(index.span(1, size: 4))
        #expect(middle.frames == 4..<8)
        #expect([UInt8](data[middle.bytes]) == stills[4..<8].flatMap { $0 })
        #expect(index.span(2, size: 4)?.frames == 8..<10)
        #expect(index.span(2, size: 4)?.bytes.upperBound == data.count)
        #expect(index.span(3, size: 4) == nil)
        #expect(index.spansOutward(from: 5, size: 4) == [1, 2, 0])
        #expect(index.spansOutward(from: 0, size: 4) == [0, 1, 2])
        #expect(index.spansOutward(from: 99, size: 4) == [2, 1, 0])
    }
}
