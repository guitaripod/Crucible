import Testing
@testable import CrucibleCore

struct DemoPhoneTourTests {
    private let steps = DemoTourStep.listed(isTV: false)

    @Test func theFirstStepLeftIsTheNextOne() {
        let rows = DemoPhoneTourPlan.rows(steps: steps, completed: [.play, .search])
        #expect(rows.map(\.step) == steps)
        #expect(rows.filter(\.isNext).map(\.step) == [.browse])
        #expect(rows.filter(\.isDone).map(\.step) == [.play, .search])
    }

    @Test func aFinishedTourHasNoNextStep() {
        let rows = DemoPhoneTourPlan.rows(steps: steps, completed: Set(steps))
        #expect(rows.allSatisfy { $0.isDone && !$0.isNext })
    }

    @Test func progressCountsOnlyTheStepsOfThePlatform() {
        #expect(DemoPhoneTourPlan.progress(steps: steps, completed: []) == "0 of 6 done")
        #expect(DemoPhoneTourPlan.progress(steps: steps, completed: [.play, .poster]) == "2 of 6 done")
        let tv = DemoTourStep.listed(isTV: true)
        #expect(DemoPhoneTourPlan.progress(steps: tv, completed: [.play, .poster]) == "1 of 4 done")
    }

    @Test func eachRowSpeaksItsStateToVoiceOver() {
        let rows = DemoPhoneTourPlan.rows(steps: steps, completed: [.play])
        #expect(rows[0].accessibilityLabel == "Play something. Resume the highlighted title and try Skip Intro. Done.")
        #expect(rows[1].accessibilityLabel.hasSuffix("Not done yet."))
    }
}
