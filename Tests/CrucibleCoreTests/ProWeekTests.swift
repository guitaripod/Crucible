import Foundation
import Testing
@testable import CrucibleCore

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_800_000_000)

struct ProWeekCalendarTests {
    @Test func theWeekRunsSevenDaysFromItsStart() {
        #expect(ProWeek.phase(start: nil, now: start) == .notStarted)
        #expect(ProWeek.phase(start: start, now: start) == .active(endsAt: start.addingTimeInterval(7 * day)))
        #expect(ProWeek.phase(start: start, now: start.addingTimeInterval(7 * day - 1)).isActive)
        #expect(ProWeek.phase(start: start, now: start.addingTimeInterval(7 * day)) == .ended(at: start.addingTimeInterval(7 * day)))
        #expect(ProWeek.phase(start: start, now: start.addingTimeInterval(90 * day)) == .ended(at: start.addingTimeInterval(7 * day)))
    }

    @Test func aClockWoundBackReadsAsTheFirstMoment() {
        #expect(ProWeek.phase(start: start, now: start.addingTimeInterval(-3 * day)) == .active(endsAt: start.addingTimeInterval(7 * day)))
    }

    @Test func aPartDayLeftCountsAsADayAndTheLastDaySaysSo() {
        let end = start.addingTimeInterval(7 * day)
        #expect(ProWeek.daysLeft(until: end, now: start) == 7)
        #expect(ProWeek.daysLeft(until: end, now: start.addingTimeInterval(0.5 * day)) == 7)
        #expect(ProWeek.daysLeft(until: end, now: end.addingTimeInterval(-60)) == 1)
        #expect(ProWeek.daysLeftText(until: end, now: start) == "Pro week · 7 days left")
        #expect(ProWeek.daysLeftText(until: end, now: end.addingTimeInterval(-60)) == "Pro week · last day")
    }

    @Test func thePaywallLeadsWithTheWeekOnlyAroundIt() throws {
        let end = start.addingTimeInterval(7 * day)
        #expect(ProWeek.paywallLine(followsProWeek: false, endsAt: nil, isTV: false) == nil)
        #expect(ProWeek.paywallLine(followsProWeek: true, endsAt: nil, isTV: false) == "Your Pro week has ended. Titles you downloaded stay on this iPhone.")
        #expect(ProWeek.paywallLine(followsProWeek: true, endsAt: nil, isTV: true) == "Your Pro week has ended.")
        let running = try #require(ProWeek.paywallLine(followsProWeek: false, endsAt: end, isTV: false))
        #expect(running.contains(ProWeek.endDateText(end)))
    }
}

@MainActor
@Suite(.serialized)
struct ProWeekAccessTests {
    private final class Clock {
        var now = start
    }

    private func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func started(_ status: ProStatus = .free, clock: Clock, store: ProWeekStore = .ephemeral()) async -> ProAccess {
        let access = ProAccess(provider: ScriptedProAccess(status: status, delay: .milliseconds(1)), weekStore: store, now: { clock.now })
        access.start()
        await settle { access.status == status }
        return access
    }

    @Test func theWeekOpensEveryFeatureWithoutMakingTheViewerABuyer() async {
        let clock = Clock()
        let access = await started(clock: clock)
        #expect(!access.hasFullAccess)
        #expect(access.startProWeekIfEligible())
        #expect(access.hasFullAccess)
        #expect(!access.isPro)
        #expect(access.proWeekEndsAt == start.addingTimeInterval(7 * day))
        #expect(access.isProWeekAnnouncementDue)
        #expect(!access.isProWeekEndNoticeDue)
    }

    @Test func theWeekWaitsForTheStoreAndIsNeverGivenToAnOwnerOrASourceBuild() async {
        let clock = Clock()
        let unanswered = ProAccess(provider: ScriptedProAccess(status: .free, delay: .seconds(30)), now: { clock.now })
        unanswered.start()
        #expect(!unanswered.startProWeekIfEligible())

        let owner = await started(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life")), clock: clock)
        #expect(!owner.startProWeekIfEligible())
        #expect(owner.proWeekPhase == .notStarted)

        let source = ProAccess(provider: UnlockedProAccess(), now: { clock.now })
        #expect(!source.startProWeekIfEligible())
    }

    @Test func observersHearTheWeekBeginAndEnd() async {
        let clock = Clock()
        let access = await started(clock: clock)
        var heard = 0
        let token = access.observe { _ in heard += 1 }
        defer { access.stopObserving(token) }
        access.startProWeekIfEligible()
        #expect(heard == 1)
        access.refreshProWeek()
        #expect(heard == 1)
        clock.now = start.addingTimeInterval(7 * day)
        access.refreshProWeek()
        #expect(heard == 2)
        #expect(!access.hasFullAccess)
        #expect(access.proWeekEndsAt == nil)
        #expect(access.isProWeekEndNoticeDue)
    }

    @Test func anAppLeftOpenLocksWhenTheWeekEnds() async {
        let clock = Clock()
        let access = await started(clock: clock)
        access.startProWeekIfEligible()
        clock.now = start.addingTimeInterval(7 * day - 0.5)
        access.refreshProWeek()
        #expect(access.hasFullAccess)
        clock.now = start.addingTimeInterval(7 * day)
        await settle { !access.hasFullAccess }
        #expect(!access.hasFullAccess)
    }

    @Test func theWeekSurvivesARelaunchAndIsNotGivenAgain() async {
        let clock = Clock()
        let store = ProWeekStore.ephemeral()
        let first = await started(clock: clock, store: store)
        first.startProWeekIfEligible()
        first.markProWeekAnnounced()
        clock.now = start.addingTimeInterval(3 * day)
        let relaunched = await started(clock: clock, store: store)
        #expect(relaunched.proWeekEndsAt == start.addingTimeInterval(7 * day))
        #expect(!relaunched.isProWeekAnnouncementDue)
        #expect(!relaunched.startProWeekIfEligible())
    }

    @Test func eachNoteIsDueOnceAndStaysSeen() async {
        let clock = Clock()
        let store = ProWeekStore.ephemeral()
        let access = await started(clock: clock, store: store)
        access.startProWeekIfEligible()
        access.markProWeekAnnounced()
        #expect(!access.isProWeekAnnouncementDue)
        clock.now = start.addingTimeInterval(8 * day)
        access.refreshProWeek()
        #expect(!access.isProWeekAnnouncementDue)
        #expect(access.isProWeekEndNoticeDue)
        access.markProWeekEndNoticeShown()
        let relaunched = await started(clock: clock, store: store)
        #expect(!relaunched.isProWeekEndNoticeDue)
    }
}

struct ProWeekTVTests {
    @Test func theYouRowCountsTheDaysWhileTheWeekRuns() {
        let end = start.addingTimeInterval(7 * day)
        #expect(ProTVPresentation.rowSubtitle(for: .free, proWeekEndsAt: end, now: start) == "Pro week · 7 days left")
        #expect(ProTVPresentation.rowSubtitle(for: .free, proWeekEndsAt: nil, now: start) == ProTVPresentation.pitch)
        let lifetime = ProStatus.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life"))
        #expect(ProTVPresentation.rowSubtitle(for: lifetime, proWeekEndsAt: end, now: start) != "Pro week · 7 days left")
    }

    @Test func thePaywallReasonPutsTheWeekBeforeTheFeature() {
        let end = start.addingTimeInterval(7 * day)
        #expect(ProTVPresentation.reasonLine(for: PaywallRequest(followsProWeek: true), proWeekEndsAt: nil) == "Your Pro week has ended.")
        #expect(ProTVPresentation.reasonLine(for: PaywallRequest(feature: .topShelf), proWeekEndsAt: end)?.contains(ProWeek.endDateText(end)) == true)
        #expect(ProTVPresentation.reasonLine(for: PaywallRequest(feature: .topShelf), proWeekEndsAt: nil) == ProTVPresentation.reasonLine(for: .topShelf))
        #expect(ProTVPresentation.reasonLine(for: PaywallRequest(), proWeekEndsAt: nil) == nil)
    }

    @Test func theWeeksNotesSayWhatTheyMean() {
        let end = start.addingTimeInterval(7 * day)
        let started = ProTVMoments.proWeekStarted(endsAt: end)
        #expect(started.kind == .proWeekStarted)
        #expect(started.action == .openStatistics)
        #expect(started.message.contains(ProWeek.endDateText(end)))
        let ended = ProTVMoments.proWeekEnded()
        #expect(ended.kind == .proWeekEnded)
        #expect(ended.action == .seePro)
    }

    @Test func theLedgerLeavesTheWeeksNotesToTheWeek() throws {
        let name = "ProWeekTVTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let ledger = ProMomentLedger(defaults: defaults)
        ledger.markShown(.proWeekStarted)
        ledger.markShown(.proWeekEnded)
        #expect(!ledger.hasShown(.proWeekStarted))
        #expect(!ledger.hasShown(.proWeekEnded))
        #expect(!ledger.hasShown(.firstFinish))
    }

    @Test func topShelfPublishesForTheWeekAndClearsAfterIt() {
        #expect(ProTVTopShelf.action(for: .free, isProWeekActive: true) == .publish)
        #expect(ProTVTopShelf.action(for: .free, isProWeekActive: false) == .clear)
        #expect(ProTVTopShelf.action(for: .unknown, isProWeekActive: true) == .wait)
    }
}

struct ProWeekTopShelfSnapshotTests {
    private let snapshot = TopShelfSnapshot(
        machineIdentifier: "m1",
        savedAt: 0,
        sections: [TopShelfSection(title: "Continue Watching", items: [
            TopShelfItem(ratingKey: "1", type: "movie", title: "Dune", subtitle: nil, imageURL: nil, progress: 0.4),
        ])]
    )

    @Test func aWeeksSnapshotStopsShowingAtTheEnd() {
        let end = start.addingTimeInterval(7 * day)
        let weekly = snapshot.available(until: end)
        #expect(TopShelfPlan(snapshot: weekly, now: end.addingTimeInterval(-1)) != nil)
        #expect(TopShelfPlan(snapshot: weekly, now: end) == nil)
        #expect(TopShelfPlan(snapshot: snapshot, now: end.addingTimeInterval(365 * day)) != nil)
    }

    @Test func buyingDuringTheWeekRewritesTheSnapshotWithoutAnEnd() {
        let weekly = snapshot.available(until: start.addingTimeInterval(7 * day))
        #expect(!weekly.hasSameContent(as: snapshot))
        #expect(weekly.available(until: nil).hasSameContent(as: snapshot))
    }

    @Test func aSnapshotFromAnEarlierVersionHasNoEnd() throws {
        let json = #"{"schema":2,"machineIdentifier":"m1","savedAt":0,"sections":[]}"#
        let decoded = try JSONDecoder().decode(TopShelfSnapshot.self, from: Data(json.utf8))
        #expect(decoded.availableUntil == nil)
        #expect(decoded.isAvailable(at: start))
    }
}
