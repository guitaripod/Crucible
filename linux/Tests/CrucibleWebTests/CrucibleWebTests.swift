import Foundation
import Testing
@testable import CrucibleWeb

enum Fixture {
    static func data(_ name: String, _ type: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: type, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func video(_ name: String) throws -> WebVideo {
        try JSONDecoder().decode(WebVideo.self, from: data(name))
    }
}

@Suite struct WebVideoTests {
    @Test func readsWhatYtDlpSaysOfAVideo() throws {
        let video = try Fixture.video("video-4k")
        #expect(video.id == "aqz-KE-bpKQ")
        #expect(video.title.hasPrefix("Big Buck Bunny"))
        #expect(video.duration == 635)
        #expect(video.channel == "Blender")
        #expect(video.site == "Youtube")
        #expect(video.liveStatus == .notLive)
        #expect(video.published != nil)
        #expect(video.heatmap.count == 4)
        #expect(video.formats.allSatisfy { $0.url != nil && !$0.isStoryboard })
        #expect(video.formats.contains { $0.id == "401" && $0.videoFamily == .av1 && $0.height == 2160 })
    }

    @Test func keepsStoryboardsApartFromWhatPlays() throws {
        let video = try Fixture.video("video-4k")
        #expect(video.storyboards.map(\.width) == [48, 80, 160, 320])
        let sharpest = try #require(video.storyboards.last)
        #expect(sharpest.rows == 3 && sharpest.columns == 3)
        #expect(sharpest.sheets.count == 15)
        #expect(sharpest.still(at: 0) == WebStoryboard.Still(sheet: 0, x: 0, y: 0, width: 320, height: 180))
        let pace = sharpest.sheets[0].duration / 9
        #expect(sharpest.still(at: pace * 4 + 0.1) == WebStoryboard.Still(sheet: 0, x: 320, y: 180, width: 320, height: 180))
        #expect(sharpest.still(at: sharpest.sheets[1].start + 0.1)?.sheet == 1)
        #expect(sharpest.still(at: 10_000)?.sheet == 14)
    }

    @Test func listsOneSubtitlePerLanguageThePublishersFirst() throws {
        let video = try Fixture.video("video-captions")
        #expect(video.subtitles.map(\.id) == ["sub:de", "sub:fi", "auto:en", "auto:sv"])
        #expect(video.subtitles.allSatisfy { $0.format == "srt" })
        #expect(video.subtitles.first { $0.id == "auto:en" }?.isOriginal == true)
        #expect(video.subtitles.first { $0.id == "auto:sv" }?.isOriginal == false)
        #expect(video.chapters.map(\.title) == ["Intro", "The Conversation", "Credits"])
    }
}

@Suite struct WebFormatPickerTests {
    @Test func picksTheTallestPictureInTheLeanestCodecWithStereoOpus() throws {
        let video = try Fixture.video("video-4k")
        let selection = try #require(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences()))
        #expect(selection.video?.id == "401")
        #expect(selection.audio?.id == "251")
        #expect(selection.quality?.label == "2160p60")
        #expect(selection.formats == ["401", "251"])
    }

    @Test func startsWithStreamsTheSiteServesAtOnce() throws {
        let video = try Fixture.video("video-captions")
        let read = try #require(video.extracted)
        let early = try #require(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(), now: read))
        #expect(early.video?.id == "625")
        #expect(early.video?.isProgressive == false)
        #expect(early.audio?.id == "234")
        #expect(early.readyAt.map { $0 <= read } == true)
        let later = try #require(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(), now: read.addingTimeInterval(10)))
        #expect(later.video?.id == "401")
        #expect(later.audio?.id == "251")
        let dubbed = try #require(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(audioLanguage: "de"), now: read))
        #expect(dubbed.audio?.id == "251-1")
        #expect(dubbed.readyAt == read.addingTimeInterval(4))
    }

    @Test func picksOnlyTheSoundWhenAsked() throws {
        let video = try Fixture.video("video-4k")
        let selection = try #require(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(soundOnly: true)))
        #expect(selection.video == nil)
        #expect(selection.audio?.id == "251")
        #expect(WebPlaybackPlan(selection)?.location == "https://media.example/videoplayback?itag=251")
    }

    @Test func leavesOutStreamsThatFailed() throws {
        let video = try Fixture.video("video-captions")
        let read = try #require(video.extracted)
        let second = try #require(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(excluded: ["625", "234"]), now: read))
        #expect(second.video?.height == 2160)
        #expect(second.video?.id != "625")
        #expect(second.audio?.id != "234")
        let everything = Set(video.formats.map(\.id))
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(excluded: everything), now: read) == nil)
    }

    @Test func staysWithinTheHeightAndTheCodecAsked() throws {
        let video = try Fixture.video("video-4k")
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(maximumHeight: 1080))?.video?.id == "399")
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(codec: .vp9))?.video?.id == "315")
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(maximumHeight: 1080, codec: .h264))?.video?.id == "299")
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(maximumHeight: 100))?.video?.height == 144)
    }

    @Test func picksSurroundOnlyWhenAsked() throws {
        let video = try Fixture.video("video-4k")
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(prefersSurround: true))?.audio?.id == "328")
    }

    @Test func listsQualitiesBestFirstAndPlaysTheOneChosen() throws {
        let video = try Fixture.video("video-4k")
        let qualities = WebFormatPicker.qualities(of: video)
        #expect(qualities.first?.label == "2160p60")
        #expect(qualities.map(\.label).contains("720p"))
        #expect(qualities.map(\.label).contains("720p60"))
        #expect(qualities.last?.label == "144p")
        #expect(Set(qualities.map(\.label)).count == qualities.count)
        let chosen = WebQuality(height: 1440, frameRate: 60, isHDR: false)
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(), quality: chosen)?.video?.id == "400")
    }

    @Test func hearsTheOriginalLanguageUnlessAnotherIsChosen() throws {
        let video = try Fixture.video("video-captions")
        #expect(WebFormatPicker.audioLanguages(of: video) == [WebAudioLanguage(code: "en", isOriginal: true), WebAudioLanguage(code: "de", isOriginal: false)])
        let later = try #require(video.extracted).addingTimeInterval(10)
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(), now: later)?.audio?.id == "251")
        #expect(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences(audioLanguage: "de"), now: later)?.audio?.id == "251-1")
    }

    @Test func joinsPictureAndSoundForMpv() throws {
        let video = try Fixture.video("video-4k")
        let selection = try #require(WebFormatPicker.pick(from: video, preferences: WebPlaybackPreferences()))
        let plan = try #require(WebPlaybackPlan(selection))
        let picture = "https://media.example/videoplayback?itag=401"
        let sound = "https://media.example/videoplayback?itag=251"
        #expect(plan.location == "edl://!new_stream;!no_clip;!no_chapters;%\(picture.utf8.count)%\(picture);!new_stream;!no_clip;!no_chapters;%\(sound.utf8.count)%\(sound)")
        #expect(plan.userAgent?.hasPrefix("Mozilla/5.0") == true)
        #expect(plan.headers == ["Accept-Language": "en-us,en;q=0.5"])
        let muxed = try #require(video.formats.first { $0.id == "18" })
        #expect(WebPlaybackPlan(WebSelection(video: muxed, audio: nil))?.location == "https://media.example/videoplayback?itag=18")
    }
}

@Suite struct WebListingTests {
    @Test func readsAChannelsTab() throws {
        let listing = try JSONDecoder().decode(WebListing.self, from: Fixture.data("listing-channel"))
        #expect(listing.channelID == "UCsXVk37bltHxD1rDPwtNM8Q")
        #expect(listing.channelHandle == "@kurzgesagt")
        #expect(listing.avatar != nil)
        #expect(listing.banner != nil)
        #expect(listing.entries.count == 5)
        let first = try #require(listing.entries.first)
        #expect(first.channel == "Kurzgesagt – In a Nutshell")
        #expect(first.channelID == "UCsXVk37bltHxD1rDPwtNM8Q")
        #expect(first.kind == .video)
        #expect(first.duration == 840)
        #expect(first.published != nil)
        #expect(first.thumbnailCandidates.first == "https://i.ytimg.com/vi/\(first.id)/hq720.jpg")
        #expect(first.thumbnailCandidates.last == "https://i.ytimg.com/vi/\(first.id)/mqdefault.jpg")
    }

    @Test func readsASearch() throws {
        let listing = try JSONDecoder().decode(WebListing.self, from: Fixture.data("listing-search"))
        #expect(listing.entries.count == 5)
        #expect(listing.entries.first?.channel == "Blender Studio")
        #expect(listing.entries.first?.viewCount == 10_991_109)
    }

    @Test func readsAChannelsFeedAndTellsShortsApart() throws {
        let feed = try #require(WebFeed(atom: Fixture.data("feed", "xml")))
        #expect(feed.channel == "Kurzgesagt – In a Nutshell")
        #expect(feed.channelID == "UCsXVk37bltHxD1rDPwtNM8Q")
        #expect(feed.entries.count == 3)
        let first = try #require(feed.entries.first)
        #expect(first.id == "NKeZ_HRk_O8")
        #expect(first.isShort)
        #expect(first.title == "Cool Down Your Room... With a FRIDGE?")
        #expect(first.published == ISO8601DateFormatter().date(from: "2026-11-14T15:00:11+00:00"))
        #expect(first.viewCount != nil)
        #expect(WebFeed.unescaped("Tom &amp; Jerry &#39;s &#x41; &bogus; &") == "Tom & Jerry 's A &bogus; &")
        #expect(WebFeed.address(channelID: "UCabc")?.absoluteString == "https://www.youtube.com/feeds/videos.xml?channel_id=UCabc")
    }
}

@Suite struct WebLinkTests {
    @Test func tellsWhatAnAddressPointsAt() {
        #expect(WebLink("https://www.youtube.com/watch?v=aqz-KE-bpKQ&t=1m30s") == .video(url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", start: 90))
        #expect(WebLink("youtu.be/aqz-KE-bpKQ?t=42") == .video(url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", start: 42))
        #expect(WebLink("https://youtube.com/shorts/NKeZ_HRk_O8") == .video(url: "https://www.youtube.com/shorts/NKeZ_HRk_O8", start: nil))
        #expect(WebLink("https://www.youtube.com/live/abcdefghijk") == .video(url: "https://www.youtube.com/watch?v=abcdefghijk", start: nil))
        #expect(WebLink("https://www.youtube.com/playlist?list=PL123") == .playlist(url: "https://www.youtube.com/playlist?list=PL123"))
        #expect(WebLink("https://www.youtube.com/@kurzgesagt/videos") == .channel(url: "https://www.youtube.com/@kurzgesagt"))
        #expect(WebLink("https://www.youtube.com/channel/UCsXVk37bltHxD1rDPwtNM8Q") == .channel(url: "https://www.youtube.com/channel/UCsXVk37bltHxD1rDPwtNM8Q"))
        #expect(WebLink("https://vimeo.com/1084537") == .other(url: "https://vimeo.com/1084537"))
        #expect(WebLink("the bear") == nil)
        #expect(WebLink("bear") == nil)
        #expect(WebLink("ftp://example.com/a") == nil)
        #expect(WebLink.seconds("1h2m3s") == 3723)
        #expect(WebLink.seconds("abc") == nil)
        #expect(WebLink.youTubeVideoID(in: "https://youtu.be/aqz-KE-bpKQ") == "aqz-KE-bpKQ")
        #expect(WebLink.youTubeVideoID(in: "https://vimeo.com/1084537") == nil)
    }
}

@Suite struct YtDlpTests {
    @Test func readsTheReasonYtDlpGave() {
        #expect(YtDlpError(standardError: "ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser") == .botCheck)
        #expect(YtDlpError(standardError: "WARNING: x\nERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video")
            == .signInRequired("Private video. Sign in if you've been granted access to this video"))
        #expect(YtDlpError(standardError: "ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader")
            == .unavailable("Video unavailable. This video has been removed by the uploader"))
        #expect(YtDlpError(standardError: "ERROR: Unsupported URL: https://example.com/") == .unsupported)
        #expect(YtDlpError(standardError: "ERROR: unable to download video data: HTTP Error 429: Too Many Requests") == .rateLimited)
        #expect(YtDlpError(standardError: "ERROR: [generic] Unable to download webpage: HTTP Error 404: Not Found (caused by <HTTPError 404: Not Found>)")
            == .network("Unable to download webpage: HTTP Error 404: Not Found"))
        #expect(YtDlpError(standardError: "") == .failed("yt-dlp failed"))
    }

    @Test func findsYtDlpWhereTheEnvironmentPoints() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crucible-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\necho 2026.01.01\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(YtDlp.locate(environment: ["PATH": "/nonexistent:\(folder.path)"])?.path == tool.path)
        #expect(YtDlp.locate(environment: ["PATH": "/nonexistent"]) == nil)
        #expect(YtDlp.locate(environment: ["CRUCIBLE_YTDLP": tool.path, "PATH": ""])?.path == tool.path)
        #expect(YtDlp.locate(environment: ["CRUCIBLE_YTDLP": "/nonexistent/yt-dlp", "PATH": folder.path]) == nil)
    }

    @Test func runsACommandAndReturnsBothStreams() async throws {
        let output = try await WebProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(output.status == 3)
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "out\n")
        #expect(output.standardError == "err\n")
    }

    @Test func endsACommandThatRunsOutOfTime() async {
        await #expect(throws: WebProcess.Failure.timedOut) {
            _ = try await WebProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: .milliseconds(300))
        }
    }

    @Test func saysWhenTheCommandIsNotThere() async {
        await #expect(throws: WebProcess.Failure.self) {
            _ = try await WebProcess.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        }
    }
}

@Suite struct SponsorBlockTests {
    @Test func asksByHashPrefixAndReadsItsOwnVideo() throws {
        let address = try #require(SponsorBlock.address(videoID: "aqz-KE-bpKQ", categories: [.sponsor, .intro]))
        #expect(address.path.hasPrefix("/api/skipSegments/"))
        #expect(address.lastPathComponent.count == 4)
        #expect(!address.absoluteString.contains("aqz-KE-bpKQ"))
        let answer = """
        [{"videoID":"other","segments":[{"category":"sponsor","actionType":"skip","segment":[1,2]}]},
         {"videoID":"aqz-KE-bpKQ","segments":[
           {"category":"sponsor","actionType":"skip","segment":[60.5,90]},
           {"category":"sponsor","actionType":"skip","segment":[80,95.25]},
           {"category":"outro","actionType":"skip","segment":[600,635]},
           {"category":"unknown_kind","actionType":"skip","segment":[300,310]},
           {"category":"intro","actionType":"skip","segment":[0,4]}]}]
        """
        #expect(SponsorBlock.segments(for: "aqz-KE-bpKQ", in: Data(answer.utf8)) == [
            SponsorBlock.Segment(category: .intro, start: 0, end: 4),
            SponsorBlock.Segment(category: .sponsor, start: 60.5, end: 95.25),
            SponsorBlock.Segment(category: .outro, start: 600, end: 635),
        ])
        #expect(SponsorBlock.segments(for: "aqz-KE-bpKQ", in: Data("Not Found".utf8)).isEmpty)
    }
}

@Suite struct WebLibraryTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("crucible-web-\(UUID().uuidString)/library.json")
    }

    private let entry = WebEntry(id: "aqz-KE-bpKQ", url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", title: "Big Buck Bunny", channel: "Blender",
                                 channelID: "UCSMOQeBJ2RAnuFungnQOxLg", duration: 635)

    @Test func keepsSubscriptionsWatchLaterAndProgressAcrossLaunches() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = WebLibrary(file: file)
        library.subscribe(to: WebChannel(id: "UCSMOQeBJ2RAnuFungnQOxLg", title: "Blender"))
        library.saveForLater(entry)
        library.record(entry, position: 120, duration: 635)
        library.flush()
        let reopened = WebLibrary(file: file)
        #expect(reopened.isSubscribed(to: "UCSMOQeBJ2RAnuFungnQOxLg"))
        #expect(reopened.subscriptions.first?.url == "https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(reopened.isSavedForLater(entry.id))
        #expect(reopened.resumePosition(of: entry.id) == 120)
        #expect(reopened.continueWatching.map(\.entry.id) == [entry.id])
    }

    @Test func aFinishedVideoStartsOverAndLeavesWatchLater() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = WebLibrary(file: file)
        library.saveForLater(entry)
        library.record(entry, position: 5, duration: 635)
        #expect(library.resumePosition(of: entry.id) == 0)
        #expect(library.continueWatching.isEmpty)
        library.record(entry, position: 620, duration: 635)
        #expect(library.watch(of: entry.id)?.isFinished == true)
        #expect(library.resumePosition(of: entry.id) == 0)
        #expect(!library.isSavedForLater(entry.id))
        #expect(library.history.count == 1)
        #expect(WebLibrary.isFinished(position: 28, duration: 30))
        #expect(!WebLibrary.isFinished(position: 12, duration: 30))
        #expect(!WebLibrary.isFinished(position: 100, duration: 0))
        library.removeFromHistory(entry.id)
        #expect(library.history.isEmpty)
        let saved = file.deletingLastPathComponent().appendingPathComponent("video.mkv")
        try? FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: saved)
        library.noteDownload(WebDownload(entry: entry, path: saved.path))
        #expect(library.download(of: entry.id)?.path == saved.path)
        try? FileManager.default.removeItem(at: saved)
        #expect(library.downloads.isEmpty)
        library.forgetDownload(entry.id)
        library.flush()
    }

    @Test func importsSubscriptionsFromOtherApps() {
        let takeout = "Channel Id,Channel Url,Channel Title\nUCsXVk37bltHxD1rDPwtNM8Q,http://www.youtube.com/channel/UCsXVk37bltHxD1rDPwtNM8Q,Kurzgesagt – In a Nutshell\nUCSMOQeBJ2RAnuFungnQOxLg,http://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg,\"Blender, the channel\"\n"
        let fromTakeout = WebSubscriptionImport.channels(in: Data(takeout.utf8))
        #expect(fromTakeout.map(\.id) == ["UCsXVk37bltHxD1rDPwtNM8Q", "UCSMOQeBJ2RAnuFungnQOxLg"])
        #expect(fromTakeout.map(\.title) == ["Kurzgesagt – In a Nutshell", "Blender, the channel"])
        let opml = #"<opml version="1.1"><body><outline text="YouTube Subscriptions"><outline text="Tom &amp; Co" title="Tom &amp; Co" type="rss" xmlUrl="https://www.youtube.com/feeds/videos.xml?channel_id=UCsXVk37bltHxD1rDPwtNM8Q" /></outline></body></opml>"#
        let fromOPML = WebSubscriptionImport.channels(in: Data(opml.utf8))
        #expect(fromOPML.map(\.id) == ["UCsXVk37bltHxD1rDPwtNM8Q"])
        #expect(fromOPML.first?.title == "Tom & Co")
        let newPipe = #"{"app_version":"0.27","subscriptions":[{"service_id":0,"url":"https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg","name":"Blender"}]}"#
        #expect(WebSubscriptionImport.channels(in: Data(newPipe.utf8)).map(\.title) == ["Blender"])
        let freeTube = "{\"name\":\"All Channels\",\"subscriptions\":[{\"id\":\"UCSMOQeBJ2RAnuFungnQOxLg\",\"name\":\"Blender\"}]}\n{\"name\":\"Music\",\"subscriptions\":[{\"id\":\"UCsXVk37bltHxD1rDPwtNM8Q\",\"name\":\"Kurzgesagt\"}]}\n"
        #expect(WebSubscriptionImport.channels(in: Data(freeTube.utf8)).count == 2)
        #expect(WebSubscriptionImport.channels(in: Data("nothing here\nUCtooShort\n".utf8)).isEmpty)
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = WebLibrary(file: file)
        #expect(library.subscribe(toAll: fromTakeout) == 2)
        #expect(library.subscribe(toAll: fromTakeout + fromOPML) == 0)
        let exported = WebSubscriptionImport.channels(in: WebSubscriptionImport.opml([WebChannel(id: "UCsXVk37bltHxD1rDPwtNM8Q", title: "Tom & \"Co\"")]))
        #expect(exported.map(\.id) == ["UCsXVk37bltHxD1rDPwtNM8Q"])
        #expect(exported.first?.title == "Tom & \"Co\"")
        library.flush()
    }
}
