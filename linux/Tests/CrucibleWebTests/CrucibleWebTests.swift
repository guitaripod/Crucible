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

@Suite struct WebShortsTests {
    private func short(_ id: String, thumbnail: String? = nil) -> WebEntry {
        WebEntry(id: id, url: "https://www.youtube.com/shorts/\(id)", title: id, thumbnail: thumbnail, isShort: true)
    }

    @Test func linesUpUnwatchedShortsFirstAndEachOnce() {
        let video = WebEntry(id: "video000001", url: "https://www.youtube.com/watch?v=video000001", title: "A video")
        let entries = [short("aaaaaaaaaaa"), video, short("bbbbbbbbbbb"), short("aaaaaaaaaaa"), short("ccccccccccc")]
        #expect(WebShorts.lineUp(entries) { $0 == "aaaaaaaaaaa" }.map(\.id) == ["bbbbbbbbbbb", "ccccccccccc", "aaaaaaaaaaa"])
        #expect(WebShorts.extended([short("aaaaaaaaaaa")], with: [short("aaaaaaaaaaa"), short("bbbbbbbbbbb")]).map(\.id) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
    }

    @Test func namesAShortsUprightPicturesBeforeTheWideOne() {
        let listed = "https://i.ytimg.com/vi/aaaaaaaaaaa/oardefault.jpg?sqp=signed"
        let entry = short("aaaaaaaaaaa", thumbnail: listed)
        #expect(entry.shortThumbnailCandidates(sharp: false).first == listed)
        #expect(entry.shortThumbnailCandidates(sharp: true).first == "https://i.ytimg.com/vi/aaaaaaaaaaa/oardefault.jpg")
        #expect(entry.shortThumbnailCandidates(sharp: true).last == "https://i.ytimg.com/vi/aaaaaaaaaaa/hq720.jpg")
        let fromFeed = short("bbbbbbbbbbb", thumbnail: "https://i4.ytimg.com/vi/bbbbbbbbbbb/hqdefault.jpg")
        #expect(fromFeed.shortThumbnailCandidates(sharp: false) == ["oardefault", "sardefault", "oar2", "hq720"].map { "https://i.ytimg.com/vi/bbbbbbbbbbb/\($0).jpg" })
    }

    @Test func fetchesNoMorePictureThanThePaneShows() throws {
        let video = try Fixture.video("video-4k")
        let heights = Set(video.formats.filter(\.hasVideo).compactMap(\.height)).sorted()
        let wide = try #require(WebShorts.heightLimit(of: video, paneWidth: 576, paneHeight: 1024, shortSide: nil))
        #expect(wide == heights.first { Double($0) >= 324 * 0.9 })
        #expect(WebShorts.heightLimit(of: video, paneWidth: 10_000, paneHeight: 10_000, shortSide: nil) == heights.last)
        #expect(WebShorts.heightLimit(of: video, paneWidth: 10_000, paneHeight: 10_000, shortSide: 720) == 720)
    }

    @Test func keepsThePlayingClipTheNextAndThePreviousOpen() {
        #expect(WebShorts.kept(around: 0, count: 5) == [0, 1])
        #expect(WebShorts.kept(around: 2, count: 5) == [2, 3, 1])
        #expect(WebShorts.kept(around: 4, count: 5) == [4, 3])
        #expect(WebShorts.isWatched(position: 43, duration: 60))
        #expect(!WebShorts.isWatched(position: 20, duration: 60))
        #expect(WebShorts.isWatched(position: 4, duration: 5))
        #expect(!WebShorts.isWatched(position: 4, duration: 0))
    }

    @Test func aWheelNotchIsOneClipWithAPauseBetweenSteps() {
        var pager = WebShortsPager()
        pager.canGoOn = true
        #expect(pager.wheel(1, at: 10) == 1)
        #expect(pager.wheel(1, at: 10.05) == 0)
        #expect(pager.wheel(1, at: 10.1) == 0)
        #expect(pager.wheel(1, at: 10.3) == 1)
        #expect(pager.wheel(-1, at: 11) == 0)
        pager.canGoBack = true
        #expect(pager.wheel(-0.5, at: 12) == 0)
        #expect(pager.wheel(-0.5, at: 12.02) == -1)
    }

    @Test func aPullMovesOnWhenItWentFarOrFastAndGivesAtTheEnds() {
        var pager = WebShortsPager()
        pager.canGoOn = true
        #expect(pager.drag(by: 0.1, at: 1) == 0.1)
        #expect(pager.release(at: 2) == 0)
        _ = pager.drag(by: 0.25, at: 3)
        #expect(pager.release(at: 4) == 1)
        _ = pager.drag(by: 0.03, at: 5)
        _ = pager.drag(by: 0.05, at: 5.02)
        #expect(pager.release(at: 5.03) == 1)
        let stretched = pager.drag(by: -0.6, at: 6)
        #expect(stretched < 0 && stretched >= -0.14)
        #expect(pager.release(at: 7) == 0)
        #expect(pager.pull == 0)
    }
}

@Suite struct YtDlpCookiesTests {
    @Test func readsAFlathubBrowsersProfileWhereOnlyThatOneIsInstalled() {
        let home = "/home/deck"
        let sandboxed = "/home/deck/.var/app/com.vivaldi.Vivaldi/config/vivaldi"
        #expect(YtDlp.cookiesArgument(for: "vivaldi", home: home) { $0 == sandboxed } == "vivaldi:\(sandboxed)")
        #expect(YtDlp.cookiesArgument(for: "vivaldi", home: home) { $0 == sandboxed || $0 == "/home/deck/.config/vivaldi" } == "vivaldi")
        #expect(YtDlp.cookiesArgument(for: "firefox", home: home) { $0 == "/home/deck/.var/app/org.mozilla.firefox/.mozilla/firefox" }
                == "firefox:/home/deck/.var/app/org.mozilla.firefox/.mozilla/firefox")
        #expect(YtDlp.cookiesArgument(for: "chrome:Profile 1", home: home) { _ in false } == "chrome:Profile 1")
        #expect(YtDlp.cookiesArgument(for: "safari", home: home) { _ in false } == "safari")
        #expect(YtDlp.cookiesArgument(for: " ", home: home) { _ in true } == nil)
    }

    @Test func tellsUnreadableCookiesFromAVideoThatNeedsAnAccount() {
        let missing = YtDlpError(standardError: #"ERROR: could not find vivaldi cookies database in "/home/deck/.config/vivaldi""#)
        #expect(missing == .cookiesUnreadable(#"could not find vivaldi cookies database in "/home/deck/.config/vivaldi""#))
        let members = YtDlpError(standardError: "ERROR: [youtube] abc: Join this channel to get access to members-only content")
        if case .signInRequired = members {} else { Issue.record("members-only content should need an account, got \(members)") }
    }
}

@Suite struct WebInboxTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, hoursAgo: Double, channel: String = "UC1") -> WebEntry {
        WebEntry(id: id, url: "https://www.youtube.com/watch?v=\(id)", title: "Video \(id)", channel: "Channel \(channel)",
                 channelID: channel, published: Self.now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test func listsEveryVideoNewestFirstWithoutRepeats() {
        let entries = [entry("a", hoursAgo: 1), entry("b", hoursAgo: 5), entry("a", hoursAgo: 1), entry("c", hoursAgo: 30)]
        let items = WebInbox.items(entries: entries, state: WebNotificationState(), watched: [], now: Self.now)
        #expect(items.map(\.id) == ["a", "b", "c"])
    }

    @Test func leavesOutMutedChannelsAndOldVideos() {
        var state = WebNotificationState()
        state.setMuted(true, channelID: "UC2")
        let entries = [entry("a", hoursAgo: 2), entry("b", hoursAgo: 2, channel: "UC2"), entry("c", hoursAgo: 61 * 24)]
        let items = WebInbox.items(entries: entries, state: state, watched: [], now: Self.now)
        #expect(items.map(\.id) == ["a"])
    }

    @Test func keepsReadingAndWatchingApartFromUnread() {
        var state = WebNotificationState()
        state.markRead(["a"], at: Self.now)
        let entries = [entry("a", hoursAgo: 1), entry("b", hoursAgo: 2), entry("c", hoursAgo: 3)]
        let items = WebInbox.items(entries: entries, state: state, watched: ["b"], now: Self.now)
        #expect(items.first { $0.id == "a" }?.isUnread == false)
        #expect(items.first { $0.id == "b" }?.isWatched == true)
        #expect(items.first { $0.id == "b" }?.isUnread == true)
        #expect(WebInbox.unreadCount(entries: entries, state: state, watched: ["b"], now: Self.now) == 2)
    }

    @Test func readsAreForgottenOldestFirst() {
        var state = WebNotificationState()
        for index in 0..<WebNotificationState.readLimit + 10 {
            state.markRead(["v\(index)"], at: Self.now.addingTimeInterval(Double(index)))
        }
        #expect(state.read.count == WebNotificationState.readLimit)
        #expect(state.isRead("v0") == false)
        #expect(state.isRead("v\(WebNotificationState.readLimit + 9)"))
    }

    @Test func watchingAVideoReadsItsNotification() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("web-watch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let library = WebLibrary(file: file)
        let video = entry("watched", hoursAgo: 1)
        library.record(video, position: 60, duration: 600, at: Self.now)
        #expect(library.notificationState.isRead(video.id))
    }

    @Test func groupsTheLastWeekByDayAndTheRestAsEarlier() {
        let calendar = Calendar(identifier: .gregorian)
        let twoHoursAgo = Self.now.addingTimeInterval(-2 * 3600)
        let yesterday = Self.now.addingTimeInterval(-26 * 3600)
        let weekday = Self.now.addingTimeInterval(-3 * 24 * 3600)
        let old = Self.now.addingTimeInterval(-20 * 24 * 3600)
        #expect(WebInbox.day(of: twoHoursAgo, now: Self.now, calendar: calendar) == .today)
        #expect(WebInbox.day(of: yesterday, now: Self.now, calendar: calendar) == .yesterday)
        #expect(WebInbox.day(of: weekday, now: Self.now, calendar: calendar) == .weekday(calendar.component(.weekday, from: weekday)))
        #expect(WebInbox.day(of: old, now: Self.now, calendar: calendar) == .earlier)
    }

    @Test func keepsWhatWasReadWithTheLibraryAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("web-library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let library = WebLibrary(file: file)
        library.markNotificationsRead(["a", "b"], at: Self.now)
        library.setNotificationMuted(true, channelID: "UC2")
        library.flush()
        let reopened = WebLibrary(file: file)
        #expect(reopened.notificationState.isRead("a"))
        #expect(reopened.notificationState.isMuted(channelID: "UC2"))
    }
}

@Suite struct YouTubeInboxTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func renderer(_ id: String, _ message: String, video: String? = "abcdefghijk", read: Bool = false,
                          comment: String? = nil) -> [String: Any] {
        var navigation: [String: Any] = [:]
        if let video {
            var command: [String: Any] = ["videoId": video]
            if let comment { command["linkedCommentId"] = comment }
            navigation["getCommentsFromInboxCommand"] = command
        }
        return [
            "notificationId": id,
            "read": read,
            "shortMessage": ["simpleText": message],
            "sentTimeText": ["simpleText": "2 hours ago"],
            "navigationEndpoint": navigation,
            "thumbnail": ["thumbnails": [["url": "https://yt3.ggpht.com/avatar-\(id)"]]],
            "videoThumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(video ?? "abcdefghijk")/hq720.jpg"]]],
        ]
    }

    private var menu: Data {
        let renderers = [
            renderer("1", "Quiet Channel replied to your comment: Nice catch", comment: "comment-1"),
            renderer("2", "Your comment got a ❤ from Another Channel"),
            renderer("3", "Your comment got a reply from Third Channel"),
            renderer("4", "Uploading Channel uploaded: A New Video", video: "zzzzzzzzzzz"),
            renderer("5", "Fourth Channel mentioned you in a comment: Hello there"),
            renderer("6", "Live Channel is live: An Evening Stream", read: true),
        ]
        let root: [String: Any] = ["mainAppWebResponseContext": ["loggedOut": false],
                                   "notifications": renderers.map { ["notificationRenderer": $0] as [String: Any] }]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    @Test func readsRepliesHeartsMentionsAndLiveNotes() throws {
        let notes = try YouTubeInbox.notes(in: menu, now: Self.now)
        #expect(notes.map(\.id) == ["n:1", "n:2", "n:3", "n:4", "n:5", "n:6"])
        #expect(notes.map(\.kind) == [.reply, .like, .reply, .upload, .mention, .live])
        #expect(notes[0].title == "Nice catch")
        #expect(notes[0].channel == "Quiet Channel")
        #expect(notes[1].title == "")
        #expect(notes[1].channel == "Another Channel")
        #expect(notes[2].title == "")
        #expect(notes[2].channel == "Third Channel")
        #expect(notes[3].title == "A New Video")
        #expect(notes[4].title == "Hello there")
        #expect(notes[4].channel == "Fourth Channel")
        #expect(notes[5].title == "An Evening Stream")
        #expect(notes[5].isRead)
        #expect(notes[0].videoID == "abcdefghijk")
        #expect(notes[0].url.contains("&lc=comment-1"))
        #expect(notes[0].publishedAt == Self.now.addingTimeInterval(-2 * 3600))
        #expect(notes[0].thumbnail?.contains("hq720.jpg") == true)
    }

    @Test func leavesOutAnAccountThatIsNotSignedIn() throws {
        let data = try JSONSerialization.data(withJSONObject: ["mainAppWebResponseContext": ["loggedOut": true]])
        #expect(throws: YouTubeInboxError.signedOut) { try YouTubeInbox.notes(in: data, now: Self.now) }
    }

    /// The real inbox, behind an opt-in: `CRUCIBLE_LIVE_BROWSER=vivaldi CRUCIBLE_LIVE_INBOX=1 swift test --filter
    /// YouTubeInboxTests`. It reads the browser's cookies and the account's menu, and prints only counts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CRUCIBLE_LIVE_INBOX"] == "1"))
    func readsTheSignedInAccountsInbox() async throws {
        let browser = try #require(ProcessInfo.processInfo.environment["CRUCIBLE_LIVE_BROWSER"])
        let executable = try #require(YtDlp.locate())
        let jar = try await YtDlp(executable: executable, cookiesBrowser: browser).cookieJar()
        let cookies = try #require(YouTubeCookies(netscape: jar))
        let notes = try await YouTubeInbox().notes(cookies: cookies)
        print("live inbox notes:", notes.count, notes.reduce(into: [String: Int]()) { $0[$1.kind.rawValue, default: 0] += 1 })
        #expect(!notes.isEmpty)
    }

    @Test func readsTheBrowsersYouTubeCookiesAndItsSignInKey() throws {
        let jar = """
        # Netscape HTTP Cookie File

        .youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tsecret-sapisid
        #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\t__Secure-3PSID\tsecure-psid
        .google.com\tTRUE\t/\tTRUE\t0\tSAPISID\tgoogle-sapisid
        .youtube.com\tTRUE\t/\tTRUE\t1\tEXPIRED\tgone
        .youtube.com\tTRUE\t/\tTRUE\t4102444800\tPREF\tkept
        """
        let cookies = try #require(YouTubeCookies(netscape: jar, now: Self.now))
        #expect(cookies.sapisid == "secret-sapisid")
        #expect(cookies.header.contains("SAPISID=secret-sapisid"))
        #expect(cookies.header.contains("__Secure-3PSID=secure-psid"))
        #expect(cookies.header.contains("PREF=kept"))
        #expect(!cookies.header.contains("google-sapisid"))
        #expect(!cookies.header.contains("EXPIRED"))
    }
}

@Suite struct WebInboxNoteTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func upload(_ id: String, channel: String = "UC1", hoursAgo: Double = 2) -> WebEntry {
        WebEntry(id: id, url: "https://www.youtube.com/watch?v=\(id)", title: "Video \(id)", channel: "Channel \(channel)",
                 channelID: channel, published: Self.now.addingTimeInterval(-hoursAgo * 3600))
    }

    private func note(_ id: String, _ kind: WebNote.Kind, video: String? = nil, channel: String = "UC9", hoursAgo: Double = 1) -> WebNote {
        WebNote(id: "n:\(id)", kind: kind, title: kind == .reply ? "Nice" : "", channel: "Commenter", channelID: channel,
                videoID: video, url: video.map { "https://www.youtube.com/watch?v=\($0)&lc=\(id)" } ?? "https://www.youtube.com/",
                publishedAt: Self.now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test func keepsCommentsAndMergesUploadAndLiveNotesIntoTheFeed() {
        let entries = [upload("v1"), upload("v2", hoursAgo: 5)]
        let notes = [note("1", .reply, video: "v1"), note("2", .upload, video: "v1"), note("3", .live, video: "v2"), note("4", .like, video: "v3")]
        let items = WebInbox.items(entries: entries, state: WebNotificationState(), watched: [], notes: notes, now: Self.now)
        #expect(items.map(\.id) == ["n:4", "n:1", "v1", "v2"])
        #expect(items.first { $0.id == "v1" }?.note == nil)
        #expect(items.first { $0.id == "v2" }?.entry.isLive == true)
        #expect(items.first { $0.id == "n:1" }?.isComment == true)
        #expect(items.first { $0.id == "n:1" }?.entry.title == "Nice")
        #expect(WebInbox.unreadCount(entries: entries, state: WebNotificationState(), watched: [], notes: notes, now: Self.now) == 4)
    }

    @Test func readsAMutedCommentsChannelAndRemembersItsReadState() {
        var state = WebNotificationState()
        state.setMuted(true, channelID: "UC9")
        state.markRead(["n:1"], at: Self.now)
        let items = WebInbox.items(entries: [], state: state, watched: [], notes: [note("1", .reply, video: "v1"), note("2", .reply, video: "v2")],
                                   now: Self.now)
        #expect(items.isEmpty)
        state.setMuted(false, channelID: "UC9")
        let unread = WebInbox.items(entries: [], state: state, watched: [], notes: [note("1", .reply, video: "v1"), note("2", .reply, video: "v2")],
                                    now: Self.now)
        #expect(unread.map(\.id) == ["n:2", "n:1"])
        #expect(unread.first { $0.id == "n:1" }?.isUnread == false)
    }

    @Test func keepsTheFirstSightingOfANoteAndReadsWhatYouTubeHadRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("web-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let library = WebLibrary(file: file)
        let first = note("1", .reply, video: "v1", hoursAgo: 3)
        library.replaceNotes([first], now: Self.now)
        var read = first
        read.isRead = true
        read.title = "edited elsewhere"
        library.replaceNotes([read], now: Self.now.addingTimeInterval(600))
        #expect(library.notes.first?.publishedAt == first.publishedAt)
        #expect(library.notificationState.isRead("n:1"))
        library.flush()
        #expect(WebLibrary(file: file).notes.first?.title == "edited elsewhere")
    }
}
