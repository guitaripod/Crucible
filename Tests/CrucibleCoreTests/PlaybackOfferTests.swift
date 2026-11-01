import Foundation
import Testing
@testable import CrucibleCore

@MainActor
@Suite(.serialized)
struct PlaybackOfferTests {
    private func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func started(_ status: ProStatus) async -> ProAccess {
        let access = ProAccess(provider: ScriptedProAccess(status: status, delay: .milliseconds(1)))
        access.start()
        await settle { access.status == status }
        return access
    }

    private func demo(active: Bool, access: ProAccess) -> DemoMode {
        let name = "PlaybackOfferTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(active, forKey: DemoMode.activeKey)
        return DemoMode(defaults: defaults, access: access)
    }

    private func recording(_ body: () async -> Void) async -> [Bool] {
        var counted: [Bool] = []
        PlaybackOffer.noteValue = { owned in
            counted.append(owned)
            return true
        }
        defer { PlaybackOffer.noteValue = { _ in false } }
        await body()
        return counted
    }

    @Test func aFreeViewersFinishIsCountedAndThePolicyDecides() async {
        let access = await started(.free)
        var offered = false
        let counted = await recording {
            offered = PlaybackOffer.noteFinishedItem(access: access, demo: demo(active: false, access: access))
        }
        #expect(offered)
        #expect(counted == [false])
    }

    @Test func anOwnersFinishIsCountedAsOwned() async {
        let access = await started(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life")))
        let counted = await recording {
            _ = PlaybackOffer.noteFinishedItem(access: access, demo: demo(active: false, access: access))
        }
        #expect(counted == [true])
    }

    @Test func theDemoAnUnansweredStoreAndASourceBuildCountNothing() async {
        let free = await started(.free)
        let unanswered = ProAccess(provider: ScriptedProAccess(status: .free, delay: .milliseconds(1)))
        let source = ProAccess(provider: UnlockedProAccess())
        var answers: [Bool] = []
        let counted = await recording {
            answers.append(PlaybackOffer.noteFinishedItem(access: free, demo: demo(active: true, access: free)))
            answers.append(PlaybackOffer.noteFinishedItem(access: unanswered, demo: demo(active: false, access: unanswered)))
            answers.append(PlaybackOffer.noteFinishedItem(access: source, demo: demo(active: false, access: source)))
        }
        #expect(answers == [false, false, false])
        #expect(counted.isEmpty)
    }
}
