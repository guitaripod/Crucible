import Foundation

/// One line of the demo tour screen: a step, whether it is done, and whether it is the one to try next.
package struct DemoPhoneTourRow: Equatable, Sendable {
    package var step: DemoTourStep
    package var isDone: Bool
    package var isNext: Bool

    package var accessibilityLabel: String {
        let state = isDone ? DemoPhoneCopy.stepDone : DemoPhoneCopy.stepNotDone
        return "\(step.title). \(step.detail) \(state)."
    }
}

/// How the tour reads on the iPhone: its rows in order, the first step left to try, and the progress words.
package enum DemoPhoneTourPlan {
    package static func rows(steps: [DemoTourStep], completed: Set<DemoTourStep>) -> [DemoPhoneTourRow] {
        let next = steps.first { !completed.contains($0) }
        return steps.map { step in
            DemoPhoneTourRow(step: step, isDone: completed.contains(step), isNext: step == next)
        }
    }

    package static func progress(steps: [DemoTourStep], completed: Set<DemoTourStep>) -> String {
        DemoPhoneCopy.progress(done: steps.filter(completed.contains).count, total: steps.count)
    }
}
