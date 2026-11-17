import Foundation
import Testing
@testable import CrucibleCore

@MainActor
@Suite(.serialized)
struct ReviewMomentsTests {
    private func demo(active: Bool) -> DemoMode {
        let defaults = UserDefaults(suiteName: "review-demo-\(UUID().uuidString)")!
        defaults.set(active, forKey: DemoMode.activeKey)
        return DemoMode(defaults: defaults)
    }

    @Test func nothingIsAskedWithoutAPolicy() {
        #expect(!ReviewMoments.finishedTitle(demo: demo(active: false)))
    }

    @Test func aFinishedTitleAsksThePolicyAndTheDemoNeverDoes() {
        var counted = 0
        let saved = ReviewMoments.noteSuccess
        defer { ReviewMoments.noteSuccess = saved }
        ReviewMoments.noteSuccess = {
            counted += 1
            return true
        }
        #expect(ReviewMoments.finishedTitle(demo: demo(active: false)))
        #expect(counted == 1)
        #expect(!ReviewMoments.finishedTitle(demo: demo(active: true)))
        #expect(counted == 1)
    }
}
