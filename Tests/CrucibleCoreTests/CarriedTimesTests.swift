import Foundation
import Testing
@testable import CrucibleCore

struct CarriedTimesTests {
    private let start = ContinuousClock.now

    @Test func zeroIsCarriedAwayFromTheRebuiltStart() {
        let times = CarriedTimes(previousClock: nil, previousPosition: nil, afterAbsence: true)
        #expect(times.isCarried(0, home: 675, at: start))
        #expect(times.isCarried(0.8, home: 675, at: start))
        #expect(!times.isCarried(675, home: 675, at: start))
        #expect(!times.isCarried(300, home: 675, at: start))
    }

    @Test func theOldClockAndTheShownPositionAreCarried() {
        let times = CarriedTimes(previousClock: 12, previousPosition: 690, afterAbsence: true)
        #expect(times.times == [0, 12, 690])
        #expect(times.isCarried(12.5, home: 675, at: start))
        #expect(times.isCarried(689.2, home: 675, at: start))
        #expect(!times.isCarried(684, home: 675, at: start))
    }

    @Test func aTimeNearTheRebuiltStartIsTheStartItself() {
        let times = CarriedTimes(previousClock: 0, previousPosition: 3, afterAbsence: true)
        #expect(!times.isCarried(0, home: 0, at: start))
        #expect(!times.isCarried(3, home: 0, at: start))
    }

    @Test func duplicatesAndUnusableTimesAreDropped() {
        let times = CarriedTimes(previousClock: 0.4, previousPosition: .nan, afterAbsence: true)
        #expect(times.times == [0])
        #expect(CarriedTimes(previousClock: -3, previousPosition: .infinity, afterAbsence: true).times == [0])
    }

    @Test func aRebuildTheViewerAskedForOnlySuspectsTheOldClock() {
        let times = CarriedTimes(previousClock: 100, previousPosition: 100, afterAbsence: false)
        #expect(times.times == [100])
        #expect(times.isCarried(100.5, home: 600, at: start))
        #expect(!times.isCarried(0, home: 600, at: start))
        #expect(CarriedTimes(previousClock: nil, previousPosition: 100, afterAbsence: false).times.isEmpty)
    }

    @Test func theTimesStaySuspectUntilTheItemHasPlayedAMoment() {
        var times = CarriedTimes(previousClock: 690, previousPosition: nil, afterAbsence: true)
        let later = start.advanced(by: .seconds(45 * 60))
        #expect(times.isCarried(0, home: 675, at: later))
        times.noteRate(playing: true, at: later)
        #expect(times.isCarried(0, home: 675, at: later.advanced(by: .seconds(2))))
        #expect(!times.isCarried(0, home: 675, at: later.advanced(by: .seconds(3))))
        times.noteRate(playing: false, at: later.advanced(by: .seconds(10)))
        #expect(!times.isActive(at: later.advanced(by: .seconds(10))))
    }

    @Test func aPauseBeforeTheGraceRunsOutStartsItAgain() {
        var times = CarriedTimes(previousClock: 690, previousPosition: nil, afterAbsence: true)
        times.noteRate(playing: true, at: start)
        times.noteRate(playing: false, at: start.advanced(by: .seconds(1)))
        times.noteRate(playing: true, at: start.advanced(by: .seconds(60)))
        #expect(times.isActive(at: start.advanced(by: .seconds(62))))
        #expect(!times.isActive(at: start.advanced(by: .seconds(63))))
    }
}
