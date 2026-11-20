import Foundation
import Testing
@testable import CrucibleCore

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@Suite(.serialized)
struct ProTasteAccessTests {
    private final class Clock {
        var now = start
    }

    private func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func started(
        _ status: ProStatus = .free, tastes: ProTasteStore = .ephemeral(), demoTastes: ProTasteStore = .ephemeral(), clock: Clock = Clock()
    ) async -> ProAccess {
        let access = ProAccess(
            provider: ScriptedProAccess(status: status, delay: .milliseconds(1)), tasteStore: tastes, demoTasteStore: demoTastes,
            now: { clock.now })
        access.start()
        await settle { access.status == status }
        return access
    }

    @Test func aViewerWithoutProGetsOneAnswerFromEachFeature() async {
        let access = await started()
        #expect(access.tasteAccess(to: .whatToWatch) == .taste)
        #expect(access.tasteAccess(to: .writtenRecap) == .taste)

        access.noteTasteGiven(.whatToWatch)
        #expect(access.tasteAccess(to: .whatToWatch) == .locked)
        #expect(access.tasteAccess(to: .writtenRecap) == .taste)

        access.noteTasteGiven(.writtenRecap)
        #expect(access.tasteAccess(to: .writtenRecap) == .locked)
    }

    @Test func askingUsesNothingUntilAnAnswerIsGiven() async {
        let access = await started()
        for _ in 0..<3 {
            #expect(access.tasteAccess(to: .whatToWatch) == .taste)
        }
    }

    @Test func aUsedTasteIsStillUsedAtTheNextLaunch() async {
        let tastes = ProTasteStore.ephemeral()
        let first = await started(tastes: tastes)
        first.noteTasteGiven(.whatToWatch)

        let next = await started(tastes: tastes)
        #expect(next.tasteAccess(to: .whatToWatch) == .locked)
        #expect(next.tasteAccess(to: .writtenRecap) == .taste)
    }

    @Test func proHasTheWholeAnswerAndUsesNoTaste() async {
        let tastes = ProTasteStore.ephemeral()
        let access = await started(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life")), tastes: tastes)
        #expect(access.tasteAccess(to: .whatToWatch) == .whole)
        access.noteTasteGiven(.whatToWatch)
        #expect(!tastes.isUsed(.whatToWatch))
    }

    @Test func aProWeekHasTheWholeAnswerAndLeavesTheTasteForAfterIt() async {
        let clock = Clock()
        let access = await started(clock: clock)
        #expect(access.startProWeekIfEligible())
        #expect(access.tasteAccess(to: .whatToWatch) == .whole)
        access.noteTasteGiven(.whatToWatch)

        clock.now = start.addingTimeInterval(8 * day)
        access.refreshProWeek()
        #expect(access.tasteAccess(to: .whatToWatch) == .taste)
    }

    @Test func aStoreThatHasNotAnsweredGivesNoTaste() {
        let access = ProAccess(provider: ScriptedProAccess(status: .free, delay: .seconds(30)))
        #expect(access.status == .unknown)
        #expect(access.tasteAccess(to: .whatToWatch) == .locked)
    }

    @Test func aSourceBuildHasTheWholeAnswer() {
        let access = ProAccess(provider: UnlockedProAccess())
        #expect(access.tasteAccess(to: .whatToWatch) == .whole)
        #expect(access.tasteAccess(to: .writtenRecap) == .whole)
    }

    @Test func theDemoUsesTastesOfItsOwnAndForgetsThemWhenItEnds() async {
        let device = ProTasteStore.ephemeral()
        let demo = ProTasteStore.ephemeral()
        let access = await started(tastes: device, demoTastes: demo)

        access.useDemoProWeek(true)
        #expect(access.tasteAccess(to: .whatToWatch) == .taste)
        access.noteTasteGiven(.whatToWatch)
        #expect(access.tasteAccess(to: .whatToWatch) == .locked)
        #expect(!device.isUsed(.whatToWatch))

        access.useDemoProWeek(false)
        #expect(access.tasteAccess(to: .whatToWatch) == .taste)

        access.useDemoProWeek(true)
        #expect(access.tasteAccess(to: .whatToWatch) == .taste)
    }

    @Test func aTasteUsedOnTheDeviceIsNotGivenAgainByTheDemoEnding() async {
        let device = ProTasteStore.ephemeral()
        let access = await started(tastes: device)
        access.noteTasteGiven(.writtenRecap)

        access.useDemoProWeek(true)
        access.useDemoProWeek(false)
        #expect(access.tasteAccess(to: .writtenRecap) == .locked)
    }

    @Test func eachTasteNamesTheProFeatureItBelongsTo() {
        #expect(ProTasteFeature.whatToWatch.proFeature == .whatToWatch)
        #expect(ProTasteFeature.writtenRecap.proFeature == .previouslyOn)
    }
}

struct DescribedRecapTasteTests {
    private static let recap = "The crew pulled off the first job and paid for it at once. An old rival surfaced with a claim on the money. "
        + "The plan for the second job fell apart over who could be trusted. By the end one of them had quietly made a deal of their own."

    @Test func aRecapStopsAfterASentenceWithMostOfItStillToCome() {
        let taste = DescribedRecap.taste(of: Self.recap)
        #expect(taste.opening == "The crew pulled off the first job and paid for it at once.")
        #expect(taste.rest.hasPrefix("An old rival surfaced"))
        #expect(taste.opening + " " + taste.rest == Self.recap)
        #expect(taste.rest.count > taste.opening.count)
    }

    private static let ending = "Nobody slept, and by morning the crew had split in two over what to do with all of it, which was the plan all along."

    @Test func aDecimalPointIsNotTheEndOfASentence() {
        let text = "The crew counted the money twice that same night and it came to 3.5 million in old notes. " + Self.ending
        let taste = DescribedRecap.taste(of: text)
        #expect(taste.opening.hasSuffix("it came to 3.5 million in old notes."))
        #expect(taste.rest == Self.ending)
    }

    @Test func aRunOfDotsIsKeptWhole() {
        let text = "The crew counted the money twice that same night and it came to less than they hoped... far less, in truth. " + Self.ending
        let taste = DescribedRecap.taste(of: text)
        #expect(taste.opening.hasSuffix("less than they hoped..."))
        #expect(taste.rest.hasPrefix("far less, in truth."))
    }

    @Test func japaneseSentencesEndWithoutASpace() {
        let text = "一行は最初の仕事をやり遂げたが、すぐに代償を払うことになった。昔の敵が金の取り分を主張して現れた。二度目の計画は、誰を信じるかで崩れた。"
            + "そして最後には、仲間の一人がひそかに自分だけの取引をしていた。"
        let taste = DescribedRecap.taste(of: text)
        #expect(taste.opening.hasSuffix("。"))
        #expect(!taste.opening.hasSuffix("…"))
        #expect(taste.opening + taste.rest == text)
        #expect(!taste.rest.isEmpty)
    }

    @Test func oneLongSentenceIsCutAtAWordAndSaysItGoesOn() {
        let text = "The crew pulled off the first job and paid for it at once when an old rival surfaced with a claim on the money "
            + "and the plan for the second job fell apart over who could be trusted while one of them quietly made a deal of their own"
        let taste = DescribedRecap.taste(of: text)
        #expect(taste.opening.hasSuffix("…"))
        #expect(!taste.opening.dropLast().hasSuffix(" "))
        #expect(text.hasPrefix(taste.opening.dropLast()))
        #expect(text.hasSuffix(taste.rest))
        #expect(taste.rest.count > taste.opening.count)
    }

    @Test func aRunWithNoSpacesIsCutPartWayThrough() {
        let text = String(repeating: "語", count: 100)
        let taste = DescribedRecap.taste(of: text)
        #expect(taste.opening == String(repeating: "語", count: 40) + "…")
        #expect(taste.rest == String(repeating: "語", count: 60))
    }

    @Test func aSentenceThatEndsTooLateDoesNotGiveTheRecapAway() {
        let text = "A. " + String(repeating: "word ", count: 30) + "and then it ended. Done."
        let taste = DescribedRecap.taste(of: text)
        #expect(taste.opening.hasSuffix("…"))
        #expect(taste.opening.count < text.count / 2)
    }

    @Test func textTooShortToSplitComesBackWhole() {
        #expect(DescribedRecap.taste(of: "") == DescribedRecap.Taste(opening: "", rest: ""))
        #expect(DescribedRecap.taste(of: "A") == DescribedRecap.Taste(opening: "A", rest: ""))
    }
}
