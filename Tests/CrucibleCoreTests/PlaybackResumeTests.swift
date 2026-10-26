import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackResumeTests {
    private func defaults() -> UserDefaults {
        let suite = "resume-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aSnapshotTakenBeforeLeavingBeatsAPlayerClockThatLostItsPlace() {
        var keeper = PlayheadKeeper()
        keeper.observe(absolute: 1_312, isReady: true)
        let snapshot = keeper.hold(observed: 0, isReady: true)
        #expect(snapshot == 1_312)
        #expect(keeper.position(observed: 0, isReady: true) == 1_312)
    }

    @Test func aReadingThatAgreesWithTheLastGoodPositionIsTheSnapshot() {
        var keeper = PlayheadKeeper()
        keeper.observe(absolute: 1_312, isReady: true)
        #expect(keeper.hold(observed: 1_313.4, isReady: true) == 1_313.4)
    }

    @Test func aReadingFromAnItemThatIsNotReadyNeverBecomesThePosition() {
        var keeper = PlayheadKeeper()
        keeper.observe(absolute: 640, isReady: true)
        keeper.observe(absolute: 0, isReady: false)
        #expect(keeper.lastGood == 640)
        #expect(keeper.position(observed: 0, isReady: false) == 640)
        #expect(keeper.hold(observed: 0, isReady: false) == 640)
    }

    @Test func readingsAreIgnoredWhileASnapshotIsHeldAndCountAgainOnceItIsReleased() {
        var keeper = PlayheadKeeper()
        keeper.observe(absolute: 500, isReady: true)
        keeper.hold(observed: 500, isReady: true)
        keeper.observe(absolute: 0, isReady: true)
        #expect(keeper.lastGood == 500)
        keeper.release()
        #expect(keeper.position(observed: 501, isReady: true) == 501)
        keeper.observe(absolute: 502, isReady: true)
        #expect(keeper.lastGood == 502)
    }

    @Test func aSnapshotAlreadyHeldIsKeptWhenHeldAgain() {
        var keeper = PlayheadKeeper()
        keeper.observe(absolute: 300, isReady: true)
        keeper.hold(observed: 300, isReady: true)
        #expect(keeper.hold(observed: 0, isReady: true) == 300)
    }

    @Test func aSeekOrRestartMovesTheHeldSnapshotWithIt() {
        var keeper = PlayheadKeeper()
        keeper.observe(absolute: 300, isReady: true)
        keeper.hold(observed: 300, isReady: true)
        keeper.moved(to: 120)
        #expect(keeper.position(observed: 0, isReady: false) == 120)
    }

    @Test func theTrackerMapsThePlayerClockOntoTheTimelineThroughTheStreamOffset() {
        let tracker = PlayheadTracker()
        tracker.setStreamOffset(1_313)
        tracker.observe(playerSeconds: 20, isReady: true)
        #expect(tracker.position(playerSeconds: 25, isReady: true) == 1_338)
        #expect(tracker.position(playerSeconds: nil, isReady: true) == 1_333)
    }

    @Test func thePositionReportedOnPauseIsTheRealOneWhenTheClockReadsTheStartOfTheStream() {
        let tracker = PlayheadTracker()
        tracker.setStreamOffset(0)
        tracker.observe(playerSeconds: 1_840, isReady: true)
        tracker.hold(playerSeconds: 1_840, isReady: true)
        #expect(tracker.position(playerSeconds: 0, isReady: true) == 1_840)
    }

    @Test func thePositionReportedAfterATranscodeRestartIsTheRestartOffsetNotTheStaleClock() {
        let tracker = PlayheadTracker()
        tracker.observe(playerSeconds: 900, isReady: true)
        tracker.hold(playerSeconds: 900, isReady: true)
        tracker.setStreamOffset(900)
        tracker.moved(to: 900)
        tracker.release()
        #expect(tracker.position(playerSeconds: 0, isReady: false) == 900)
        #expect(tracker.position(playerSeconds: 3, isReady: true) == 903)
    }

    @Test func aTranscodeIsRebuiltAtTheTargetSoAnExpiredSessionNeverMatters() {
        #expect(ReturnPlan.make(target: 1_840, isDirectPlay: false) == .restartTranscode(at: 1_840))
    }

    @Test func aDirectPlayFileIsSeekedToTheTargetOnReturn() {
        #expect(ReturnPlan.make(target: 600, isDirectPlay: true) == .seek(to: 600))
    }

    @Test func aTranscodeFailureSoonAfterTheReturnIsRestartedOnceNotShownAsAnError() {
        var policy = PlaybackFailurePolicy()
        policy.noteReturn()
        #expect(policy.decide(wasDirectPlay: false, isOffline: false, justReturned: true) == .restartTranscode)
        #expect(policy.decide(wasDirectPlay: false, isOffline: false, justReturned: true) == .fail)
    }

    @Test func aTranscodeFailureLongAfterTheReturnStillFailsAtOnce() {
        var policy = PlaybackFailurePolicy()
        #expect(policy.decide(wasDirectPlay: false, isOffline: false, justReturned: false) == .fail)
    }

    @Test func eachReturnEarnsOneRestart() {
        var policy = PlaybackFailurePolicy()
        #expect(policy.decide(wasDirectPlay: false, isOffline: false, justReturned: true) == .restartTranscode)
        policy.noteReturn()
        #expect(policy.decide(wasDirectPlay: false, isOffline: false, justReturned: true) == .restartTranscode)
    }

    @Test func aPositionSurvivesATerminatedProcess() {
        let defaults = defaults()
        let now = Date()
        PlaybackResumeStore(defaults: defaults).save(server: "srv", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400, now: now)
        let restored = PlaybackResumeStore(defaults: defaults).point(server: "srv", ratingKey: "7")
        #expect(restored?.positionSecs == 1_312.6)
        #expect(restored?.needsReport == true)
    }

    @Test func aPositionTheServerAcceptedNeedsNoReportAtTheNextLaunch() {
        let store = PlaybackResumeStore(defaults: defaults())
        store.save(server: "srv", ratingKey: "7", positionSecs: 600, durationSecs: 2_400)
        store.recordReport(server: "srv", ratingKey: "7", positionSecs: 599)
        #expect(store.pendingReports(server: "srv").isEmpty)
        store.save(server: "srv", ratingKey: "7", positionSecs: 640, durationSecs: 2_400)
        #expect(store.pendingReports(server: "srv").map(\.positionSecs) == [640])
    }

    @Test func aFinishedItemIsForgotten() {
        let store = PlaybackResumeStore(defaults: defaults())
        store.save(server: "srv", ratingKey: "7", positionSecs: 600, durationSecs: 2_400)
        store.save(server: "srv", ratingKey: "7", positionSecs: 2_300, durationSecs: 2_400)
        #expect(store.point(server: "srv", ratingKey: "7") == nil)
    }

    @Test func positionsAreKeptPerServerAndExpireWithTheNextSave() {
        let store = PlaybackResumeStore(defaults: defaults())
        let old = Date().addingTimeInterval(-ResumePoint.lifetime - 60)
        store.save(server: "a", ratingKey: "7", positionSecs: 100, durationSecs: 2_400, now: old)
        store.save(server: "b", ratingKey: "7", positionSecs: 200, durationSecs: 2_400)
        #expect(store.pendingReports(server: "a").isEmpty)
        #expect(store.pendingReports(server: "b").map(\.positionSecs) == [200])
        #expect(store.point(server: "a", ratingKey: "7") == nil)
        #expect(store.point(server: "b", ratingKey: "7")?.positionSecs == 200)
    }

    @Test func theStoreKeepsOnlyTheNewestPositions() {
        let store = PlaybackResumeStore(defaults: defaults())
        let base = Date()
        for index in 0..<30 {
            store.save(server: "srv", ratingKey: "\(index)", positionSecs: 100, durationSecs: 2_400, now: base.addingTimeInterval(TimeInterval(index)))
        }
        #expect(store.pendingReports(server: "srv", now: base.addingTimeInterval(30)).count == 20)
        #expect(store.point(server: "srv", ratingKey: "29") != nil)
        #expect(store.point(server: "srv", ratingKey: "0") == nil)
    }

    @Test func aSavedPositionReplacesTheServersOffsetUnlessSomeoneWatchedFurtherSince() {
        let saved = Date()
        let point = ResumePoint(server: "srv", ratingKey: "7", positionSecs: 1_312, durationSecs: 2_400, savedAt: saved)
        #expect(ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 1_300, serverViewedAt: saved.addingTimeInterval(-30)))
        #expect(ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 0, serverViewedAt: nil))
        #expect(!ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 1_311, serverViewedAt: nil))
        #expect(!ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 2_000, serverViewedAt: saved.addingTimeInterval(3_600)))
        #expect(ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 0, serverViewedAt: saved.addingTimeInterval(30)))
    }

    @Test func theNextLaunchTellsTheServerWhereTheTerminatedRunLeftTheViewer() async {
        let server = DetailStubServer()
        server.reply(path: "/library/metadata/7", items: [DetailFixtures.item(["ratingKey": "7", "duration": 2_400_000, "viewOffset": 12_000])])
        server.reply(path: "/:/timeline")
        let store = PlaybackResumeStore(defaults: defaults())
        store.save(server: "srv", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400)

        await PlaybackResumeSync.flush(api: server.client, server: "srv", store: store)

        let timeline = server.requestedURLs.first { $0.contains("/:/timeline") }
        #expect(timeline?.contains("time=1312600") == true)
        #expect(timeline?.contains("state=stopped") == true)
        #expect(store.pendingReports(server: "srv").isEmpty)
    }

    @Test func aServerThatAlreadyHoldsThePositionIsNotToldAgain() async {
        let server = DetailStubServer()
        server.reply(path: "/library/metadata/7", items: [DetailFixtures.item(["ratingKey": "7", "duration": 2_400_000, "viewOffset": 1_312_000])])
        server.reply(path: "/:/timeline")
        let store = PlaybackResumeStore(defaults: defaults())
        store.save(server: "srv", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400)

        await PlaybackResumeSync.flush(api: server.client, server: "srv", store: store)

        #expect(!server.requests.contains("/:/timeline"))
        #expect(store.pendingReports(server: "srv").isEmpty)
    }

    @Test func anUnreachableServerLeavesThePositionForTheNextLaunch() async {
        let server = DetailStubServer()
        server.failTransport(path: "/library/metadata/7")
        let store = PlaybackResumeStore(defaults: defaults())
        store.save(server: "srv", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400)

        await PlaybackResumeSync.flush(api: server.client, server: "srv", store: store)

        #expect(store.pendingReports(server: "srv").map(\.positionSecs) == [1_312.6])
    }

    @Test func aPositionOfAnotherServerIsNeverSent() async {
        let server = DetailStubServer()
        let store = PlaybackResumeStore(defaults: defaults())
        store.save(server: "elsewhere", ratingKey: "7", positionSecs: 1_312.6, durationSecs: 2_400)

        await PlaybackResumeSync.flush(api: server.client, server: "srv", store: store)

        #expect(server.requests.isEmpty)
    }
}
