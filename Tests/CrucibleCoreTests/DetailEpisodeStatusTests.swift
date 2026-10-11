import Foundation
import Testing
@testable import CrucibleCore

struct DetailEpisodeStatusTests {
    @Test func plainEpisodeShowsOnlyItsNumber() {
        let status = EpisodeStatus(episode: DetailFixtures.episode(3), isUpNext: false)
        #expect(status.eyebrow == "E3")
        #expect(status.marker == .plain)
        #expect(!status.marker.isEmphasised)
        #expect(status.metaText == "40 min")
        #expect(status.progress == nil)
        #expect(!status.isInProgress)
        #expect(status.contentAlpha == 1)
    }

    @Test func missingNumberFallsBackToTheWordEpisode() {
        let status = EpisodeStatus(episode: DetailFixtures.item(["type": "episode", "title": "Special"]), isUpNext: false)
        #expect(status.eyebrow == "EPISODE")
    }

    @Test func watchedBeatsEveryOtherMarker() {
        let episode = DetailFixtures.episode(2, watched: true, offsetMs: 600_000)
        let status = EpisodeStatus(episode: episode, isUpNext: true, download: .progress(0.5))
        #expect(status.eyebrow == "E2 · WATCHED")
        #expect(status.marker == .watched)
        #expect(status.isWatched)
        #expect(!status.isInProgress)
        #expect(status.progress == nil)
        #expect(status.contentAlpha == 0.55)
        #expect(status.metaParts == ["40 min", "50%"])
    }

    @Test func continueBeatsDownloadingAndUpNext() {
        let episode = DetailFixtures.episode(2, offsetMs: 600_000)
        let status = EpisodeStatus(episode: episode, isUpNext: true, download: .queued)
        #expect(status.eyebrow == "E2 · CONTINUE")
        #expect(status.marker == .inProgress)
        #expect(status.marker.isEmphasised)
        #expect(status.isInProgress)
        #expect(abs((status.progress ?? 0) - 0.25) < 0.0001)
        #expect(status.metaParts == ["40 min", "30 min left", "Queued"])
    }

    @Test func downloadingBeatsUpNext() {
        let status = EpisodeStatus(episode: DetailFixtures.episode(2), isUpNext: true, download: .progress(0.4))
        #expect(status.eyebrow == "E2 · DOWNLOADING")
        #expect(status.marker == .downloading)
        #expect(!status.marker.isEmphasised)
    }

    @Test func pausedAndCompletedDownloadsDoNotChangeTheEyebrow() {
        #expect(EpisodeStatus(episode: DetailFixtures.episode(2), isUpNext: true, download: .paused(0.4)).marker == .upNext)
        #expect(EpisodeStatus(episode: DetailFixtures.episode(2), isUpNext: false, download: .completed).marker == .plain)
    }

    @Test func upNextIsEmphasised() {
        let status = EpisodeStatus(episode: DetailFixtures.episode(4), isUpNext: true)
        #expect(status.eyebrow == "E4 · UP NEXT")
        #expect(status.marker.isEmphasised)
    }

    @Test func downloadStatesAppendToTheMetaLine() {
        func meta(_ download: DownloadBadge) -> String {
            EpisodeStatus(episode: DetailFixtures.episode(1), isUpNext: false, download: download).metaText
        }
        #expect(meta(.idle) == "40 min")
        #expect(meta(.progress(0.424)) == "40 min · 42%")
        #expect(meta(.queued) == "40 min · Queued")
        #expect(meta(.paused(0.5)) == "40 min · Paused · 50%")
        #expect(meta(.completed) == "40 min · Downloaded")
        #expect(meta(.failed) == "40 min · Download failed")
    }

    @Test func metaLineIsEmptyWithoutRuntime() {
        let status = EpisodeStatus(episode: DetailFixtures.item(["type": "episode", "index": 1]), isUpNext: false)
        #expect(status.metaParts.isEmpty)
        #expect(status.metaText == "")
    }

    @Test func spokenTextDescribesNumberTitleTimeAndDownload() {
        let fresh = EpisodeStatus(episode: DetailFixtures.episode(3, title: "Low Tide"), isUpNext: false)
        #expect(fresh.spokenText.hasPrefix("Episode 3, Low Tide, "))
        #expect(fresh.spokenText.contains("minute"))

        let watched = EpisodeStatus(episode: DetailFixtures.episode(3, watched: true, title: "Low Tide"), isUpNext: false, download: .completed)
        #expect(watched.spokenText == "Episode 3, Low Tide, watched, downloaded")

        let partway = EpisodeStatus(episode: DetailFixtures.episode(3, offsetMs: 600_000, title: "Low Tide"), isUpNext: false, download: .paused(0.3))
        #expect(partway.spokenText.hasPrefix("Episode 3, Low Tide, "))
        #expect(partway.spokenText.contains(" left"))
        #expect(partway.spokenText.hasSuffix("download paused at 30 percent"))

        let unnumbered = EpisodeStatus(episode: DetailFixtures.item(["type": "episode", "title": "Special"]), isUpNext: false)
        #expect(unnumbered.spokenText == "Special")
    }

    @Test func actionTitlesFollowTheEpisodeState() {
        let fresh = EpisodeStatus(episode: DetailFixtures.episode(1), isUpNext: false)
        #expect(fresh.playTitle == "Play")
        #expect(!fresh.canPlayFromBeginning)
        #expect(fresh.watchedToggleTitle == "Mark Watched")

        let partway = EpisodeStatus(episode: DetailFixtures.episode(1, offsetMs: 1_000), isUpNext: false)
        #expect(partway.playTitle == "Resume")
        #expect(partway.canPlayFromBeginning)

        let watched = EpisodeStatus(episode: DetailFixtures.episode(1, watched: true), isUpNext: false)
        #expect(watched.watchedToggleTitle == "Mark Unwatched")
    }

    @Test func downloadBadgeFragments() {
        #expect(DownloadBadge.idle.metaText == nil)
        #expect(DownloadBadge.idle.spokenText == nil)
        #expect(DownloadBadge.progress(0.5).spokenText == "downloading 50 percent")
        #expect(DownloadBadge.queued.spokenText == "download queued")
        #expect(DownloadBadge.failed.spokenText == "download failed")
        #expect(DownloadBadge.progress(0.1).isDownloading)
        #expect(DownloadBadge.queued.isDownloading)
        #expect(!DownloadBadge.paused(0.1).isDownloading)
        #expect(!DownloadBadge.completed.isDownloading)
    }
}
