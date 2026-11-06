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

    private func started(_ status: ProStatus, now: @escaping () -> Date = Date.init) async -> ProAccess {
        let access = ProAccess(provider: ScriptedProAccess(status: status, delay: .milliseconds(1)), now: now)
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

    @Test func aFreeViewersFirstFinishStartsTheProWeekInsteadOfAnOffer() async {
        let access = await started(.free)
        var outcome = PlaybackOffer.Outcome.nothing
        let counted = await recording {
            outcome = PlaybackOffer.noteFinishedItem(access: access, demo: demo(active: false, access: access))
        }
        #expect(outcome == .proWeekStarted)
        #expect(counted.isEmpty)
        #expect(access.hasFullAccess)
        #expect(!access.isPro)
    }

    @Test func theWeekIsAnnouncedUntilAScreenShowsIt() async {
        let access = await started(.free)
        let finish = { PlaybackOffer.noteFinishedItem(access: access, demo: self.demo(active: false, access: access)) }
        #expect(finish() == .proWeekStarted)
        #expect(finish() == .proWeekStarted)
        access.markProWeekAnnounced()
        let counted = await recording { #expect(finish() == .nothing) }
        #expect(counted == [false])
    }

    @Test func afterTheWeekTheEndNoteComesOnceThenThePolicyDecides() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let access = await started(.free, now: { clock })
        let finish = { PlaybackOffer.noteFinishedItem(access: access, demo: self.demo(active: false, access: access)) }
        #expect(finish() == .proWeekStarted)
        access.markProWeekAnnounced()

        clock = clock.addingTimeInterval(ProWeek.length + 60)
        access.refreshProWeek()
        #expect(!access.hasFullAccess)
        _ = await recording { #expect(finish() == .proWeekEnded) }
        access.markProWeekEndNoticeShown()
        _ = await recording { #expect(finish() == .offer) }
    }

    @Test func aBuyerDuringTheWeekHearsNoEndNote() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = ScriptedProAccess(status: .free, delay: .milliseconds(1))
        let access = ProAccess(provider: provider, now: { clock })
        access.start()
        await settle { access.status == .free }
        #expect(access.startProWeekIfEligible())
        access.apply(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life")))
        clock = clock.addingTimeInterval(ProWeek.length * 2)
        access.refreshProWeek()
        #expect(!access.isProWeekEndNoticeDue)
        #expect(access.proWeekEndsAt == nil)
        #expect(access.hasFullAccess)
    }

    @Test func theWeekIsGivenOnce() async {
        let access = await started(.free)
        #expect(access.startProWeekIfEligible())
        #expect(!access.startProWeekIfEligible())
    }

    @Test func anOwnersFinishIsCountedAsOwned() async {
        let access = await started(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life")))
        var outcome = PlaybackOffer.Outcome.nothing
        let counted = await recording {
            outcome = PlaybackOffer.noteFinishedItem(access: access, demo: demo(active: false, access: access))
        }
        #expect(counted == [true])
        #expect(outcome == .offer)
        #expect(access.proWeekPhase == .notStarted)
    }

    @Test func theDemoAnUnansweredStoreAndASourceBuildCountNothing() async {
        let free = await started(.free)
        let unanswered = ProAccess(provider: ScriptedProAccess(status: .free, delay: .milliseconds(1)))
        let source = ProAccess(provider: UnlockedProAccess())
        var answers: [PlaybackOffer.Outcome] = []
        let counted = await recording {
            answers.append(PlaybackOffer.noteFinishedItem(access: free, demo: demo(active: true, access: free)))
            answers.append(PlaybackOffer.noteFinishedItem(access: unanswered, demo: demo(active: false, access: unanswered)))
            answers.append(PlaybackOffer.noteFinishedItem(access: source, demo: demo(active: false, access: source)))
        }
        #expect(answers == [.nothing, .nothing, .nothing])
        #expect(free.proWeekPhase == .notStarted && unanswered.proWeekPhase == .notStarted && source.proWeekPhase == .notStarted)
        #expect(counted.isEmpty)
    }

    @Test func theDemosFreePreviewStartsAWeekOfItsOwnAndNeverCountsTowardTheOfferPolicy() async {
        let access = await started(.free)
        let mode = demo(active: true, access: access)
        mode.setPreviewsFreeVersion(true)
        access.useDemoProWeek(true)
        var answers: [PlaybackOffer.Outcome] = []
        let counted = await recording {
            answers.append(PlaybackOffer.noteFinishedItem(access: access, demo: mode))
            access.markProWeekAnnounced()
            answers.append(PlaybackOffer.noteFinishedItem(access: access, demo: mode))
        }
        #expect(answers == [.proWeekStarted, .nothing])
        #expect(counted.isEmpty)
        #expect(access.hasFullAccess && !access.isPro)
        access.useDemoProWeek(false)
        #expect(access.proWeekPhase == .notStarted)
        #expect(!access.hasFullAccess)
        access.useDemoProWeek(true)
        #expect(access.proWeekPhase == .notStarted, "leaving the demo forgets its week")
    }

    @Test func anOfferShownInTheDemoIsNotRecorded() {
        let access = ProAccess(provider: UnlockedProAccess())
        var recorded = 0
        PlaybackOffer.noteOffered = { recorded += 1 }
        defer { PlaybackOffer.noteOffered = {} }
        PlaybackOffer.recordOffer(demo: demo(active: true, access: access))
        #expect(recorded == 0)
        PlaybackOffer.recordOffer(demo: demo(active: false, access: access))
        #expect(recorded == 1)
    }
}
