import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct DemoTourTests {
    private func tour(isTV: Bool = false) -> DemoTour {
        DemoTour(defaults: UserDefaults(suiteName: "demo-tour-\(UUID().uuidString)")!, isTV: isTV)
    }

    @Test func eachPlatformListsTheStepsItHas() {
        #expect(DemoTourStep.listed(isTV: false).contains(.download))
        #expect(!DemoTourStep.listed(isTV: true).contains(.download))
        #expect(!DemoTourStep.listed(isTV: true).contains(.poster))
        #expect(DemoTourStep.listed(isTV: true) == [.play, .browse, .search, .statistics])
    }

    @Test func stepsOnlyCountInsideTheDemo() {
        let tour = tour()
        tour.record(.play, demoActive: false)
        #expect(tour.completedCount == 0)
        tour.record(.play, demoActive: true)
        #expect(tour.completed == [.play])
    }

    @Test func aStepCountsOnce() {
        let tour = tour()
        tour.record(.browse, demoActive: true)
        tour.record(.browse, demoActive: true)
        #expect(tour.completedCount == 1)
    }

    @Test func aStepTheTelevisionDoesNotHaveIsIgnored() {
        let tour = tour(isTV: true)
        tour.record(.download, demoActive: true)
        tour.record(.poster, demoActive: true)
        #expect(tour.completedCount == 0)
    }

    @Test func theTelevisionFinaleFiresWhenItsFourStepsAreDone() {
        let tour = tour(isTV: true)
        var fired = 0
        tour.onFinale = { fired += 1 }
        for step in DemoTourStep.listed(isTV: true) { tour.record(step, demoActive: true) }
        #expect(fired == 1)
        #expect(tour.isComplete)
    }

    @Test func theFinaleFiresOnceWhenEnoughStepsAreDone() {
        let tour = tour()
        var fired = 0
        tour.onFinale = { fired += 1 }
        for step in [DemoTourStep.play, .browse, .search] { tour.record(step, demoActive: true) }
        #expect(fired == 0)
        tour.record(.statistics, demoActive: true)
        #expect(fired == 1)
        tour.record(.poster, demoActive: true)
        tour.record(.download, demoActive: true)
        #expect(fired == 1)
        #expect(tour.finaleShown)
        #expect(tour.isComplete)
    }

    @Test func beginningAgainStartsOver() {
        let tour = tour()
        for step in DemoTourStep.allCases { tour.record(step, demoActive: true) }
        tour.begin()
        #expect(tour.completedCount == 0)
        #expect(!tour.finaleShown)
    }

    @Test func observersHearProgress() {
        let tour = tour()
        var changes = 0
        let token = tour.observe { changes += 1 }
        tour.record(.play, demoActive: true)
        tour.stopObserving(token)
        tour.record(.browse, demoActive: true)
        #expect(changes == 1)
    }
}
