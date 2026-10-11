import Foundation
import Testing
@testable import CrucibleCore

struct PlaybackRulesTests {
    @Test func aDirectPlayFailureFallsBackToTheTranscoderOnce() {
        var policy = PlaybackFailurePolicy()
        #expect(policy.decide(wasDirectPlay: true, isOffline: false) == .fallBackToTranscode)
        #expect(policy.decide(wasDirectPlay: false, isOffline: false) == .fail)
    }

    @Test func aSecondDirectPlayFailureIsReportedNotRetried() {
        var policy = PlaybackFailurePolicy()
        _ = policy.decide(wasDirectPlay: true, isOffline: false)
        #expect(policy.decide(wasDirectPlay: true, isOffline: false) == .fail)
    }

    @Test func transcodeAndOfflineFailuresAreReportedAtOnce() {
        var transcode = PlaybackFailurePolicy()
        #expect(transcode.decide(wasDirectPlay: false, isOffline: false) == .fail)
        var offline = PlaybackFailurePolicy()
        #expect(offline.decide(wasDirectPlay: true, isOffline: true) == .fail)
    }

    @Test func failuresAfterTheReportedOneAreIgnored() {
        var policy = PlaybackFailurePolicy()
        #expect(policy.decide(wasDirectPlay: false, isOffline: false) == .fail)
        #expect(policy.decide(wasDirectPlay: false, isOffline: false) == .ignore)
        #expect(policy.decide(wasDirectPlay: true, isOffline: false) == .ignore)
    }

    @Test func aFailedFallbackSilencesLaterNotifications() {
        var policy = PlaybackFailurePolicy()
        _ = policy.decide(wasDirectPlay: true, isOffline: false)
        policy.recordFailure()
        #expect(policy.decide(wasDirectPlay: false, isOffline: false) == .ignore)
    }

    @Test func theFallbackResumesWhereThePlayheadWasOtherwiseAtTheResumePosition() {
        #expect(PlaybackFailurePolicy.fallbackStart(lastAbsolute: 0, resumePosition: 90) == 90)
        #expect(PlaybackFailurePolicy.fallbackStart(lastAbsolute: 1_234, resumePosition: 90) == 1_234)
        #expect(PlaybackFailurePolicy.fallbackStart(lastAbsolute: 0, resumePosition: 0) == 0)
    }

    @Test func failureDescriptionsNameDomainCodeAndReason() {
        #expect(PlaybackFailurePolicy.describe(domain: "AVFoundationErrorDomain", code: -11800, description: "The operation could not be completed", unknown: "unknown")
            == "AVFoundationErrorDomain#-11800: The operation could not be completed")
        #expect(PlaybackFailurePolicy.describe(domain: nil, code: nil, description: nil, unknown: "unknown") == "?#0: unknown")
        #expect(PlaybackFailurePolicy.describe(domain: nil, code: nil, description: nil, unknown: "failed to play to end") == "?#0: failed to play to end")
    }

    @Test func aTranscodeResumesThroughItsUrlAndIsNeverSeeked() {
        #expect(ResumeStrategy.make(resumePosition: 600, isDirectPlay: false, isOffline: false) == .none)
        #expect(ResumeStrategy.streamOffset(resumePosition: 600, isDirectPlay: false) == 600)
    }

    @Test func aDirectPlayFileSeeksExactlyAndHasNoStreamOffset() {
        #expect(ResumeStrategy.make(resumePosition: 600, isDirectPlay: true, isOffline: false) == .seekExact(600))
        #expect(ResumeStrategy.streamOffset(resumePosition: 600, isDirectPlay: true) == 0)
    }

    @Test func aDownloadSeeksOnceItIsReady() {
        #expect(ResumeStrategy.make(resumePosition: 600, isDirectPlay: true, isOffline: true) == .seekWhenReady(600))
    }

    @Test func noStoredPositionMeansNoSeekAtAll() {
        #expect(ResumeStrategy.make(resumePosition: 0, isDirectPlay: true, isOffline: false) == .none)
        #expect(ResumeStrategy.make(resumePosition: 0, isDirectPlay: true, isOffline: true) == .none)
        #expect(ResumeStrategy.make(resumePosition: 0, isDirectPlay: false, isOffline: false) == .none)
    }

    @Test func positionsAddTheStreamOffsetAndRejectUnusableClocks() {
        #expect(StreamPosition.absolute(playerSeconds: 30, streamOffset: 600) == 630)
        #expect(StreamPosition.absolute(playerSeconds: 0, streamOffset: 0) == 0)
        #expect(StreamPosition.absolute(playerSeconds: .nan, streamOffset: 0) == nil)
        #expect(StreamPosition.absolute(playerSeconds: .infinity, streamOffset: 0) == nil)
        #expect(StreamPosition.absolute(playerSeconds: -1, streamOffset: 0) == nil)
    }

    @Test func onlyJumpsOverFiveSecondsRestartATranscode() {
        #expect(!TranscodeSeekPolicy.isJump(from: 10, to: 15))
        #expect(TranscodeSeekPolicy.isJump(from: 10, to: 15.1))
        #expect(TranscodeSeekPolicy.isJump(from: 100, to: 40))
        #expect(!TranscodeSeekPolicy.isJump(from: 0, to: 0.5))
    }

    @Test func anItemIsWatchedFromNinetyTwoPercent() {
        #expect(!WatchedRule.isWatched(positionMs: 919, durationMs: 1_000))
        #expect(WatchedRule.isWatched(positionMs: 920, durationMs: 1_000))
        #expect(WatchedRule.isWatched(positionMs: 1_000, durationMs: 1_000))
    }

    @Test func nothingIsWatchedWithoutADurationOrAPosition() {
        #expect(!WatchedRule.isWatched(positionMs: 500, durationMs: 0))
        #expect(!WatchedRule.isWatched(positionMs: 0, durationMs: 1_000))
        #expect(!WatchedRule.isWatched(positionMs: 0, durationMs: 0))
    }

    @Test func progressIsCappedAtOne() {
        #expect(WatchedRule.progress(positionMs: 1_500, durationMs: 1_000) == 1)
        #expect(WatchedRule.progress(positionMs: 250, durationMs: 1_000) == 0.25)
        #expect(WatchedRule.progress(positionMs: 250, durationMs: 0) == 0)
    }

    @Test func requestsFromAnItemCarryItsIdentityResumeAndMetadata() throws {
        let json = """
        {"ratingKey":"302","type":"episode","title":"Low Tide","grandparentTitle":"The Show","grandparentRatingKey":"100",
         "grandparentThumb":"/show/thumb","parentRatingKey":"200","parentIndex":2,"index":4,"viewOffset":600000,"duration":2700000}
        """
        let item = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        let request = PlaybackRequest(item: item, selectedSubtitleId: 7)
        #expect(request.ratingKey == "302")
        #expect(request.isEpisode)
        #expect(request.showRatingKey == "100")
        #expect(request.seasonRatingKey == "200")
        #expect(request.resumePosition == 600)
        #expect(request.transcodeStartSecs == 600)
        #expect(request.selectedSubtitleId == 7)
        #expect(request.selectedAudioStreamId == nil)
        #expect(request.durationSecs == 2_700)
        #expect(request.metadata == PlaybackMetadata(title: "Low Tide", showName: "The Show", seasonNumber: 2, episodeNumber: 4, posterPath: "/show/thumb", duration: 2_700))
        #expect(PlaybackRequest(item: item, resumePosition: 0).transcodeStartSecs == nil)
    }

    @Test func anOfflineDurationWinsOverTheMetadataDuration() {
        let metadata = PlaybackMetadata(title: "T", showName: nil, seasonNumber: nil, episodeNumber: nil, posterPath: nil, duration: 100)
        let source = OfflinePlaybackSource(fileURL: URL(string: "http://127.0.0.1:1/a.m3u8")!, markers: [], durationSecs: 250)
        let withSource = PlaybackRequest(ratingKey: "1", mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil, resumePosition: 0, metadata: metadata, offline: source)
        let withoutSource = PlaybackRequest(ratingKey: "1", mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil, resumePosition: 0, metadata: metadata)
        let bare = PlaybackRequest(ratingKey: "1", mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil, resumePosition: 0)
        #expect(withSource.durationSecs == 250)
        #expect(withoutSource.durationSecs == 100)
        #expect(bare.durationSecs == 0)
        #expect(!bare.isEpisode)
    }
}
