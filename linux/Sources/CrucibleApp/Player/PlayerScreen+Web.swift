import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// A web video handed to the player.
struct WebPlayback {
    var entry: WebEntry
    /// The moment to start at when a link names one; otherwise the video carries on where the viewer left it.
    var start: Double?
    /// What plays after this one: the rest of a playlist.
    var queue: [WebEntry] = []
}

/// The web side of one player: what yt-dlp said of the video, what the viewer chose from it, and what goes with it.
@MainActor
final class WebSession {
    var playback: WebPlayback
    var video: WebVideo?
    var selection: WebSelection?
    /// The quality the viewer picked, or nil while the picker chooses.
    var chosenQuality: WebQuality?
    var audioLanguage: String?
    /// The subtitle tracks offered, in menu order; a track's stream id is its place here, from 1.
    var subtitles: [WebSubtitle] = []
    var chosenSubtitle: Int?
    var sponsor: [SponsorBlock.Segment] = []
    var stills: WebStoryboardLoader?
    var savedPosition: Double = -1
    /// When yt-dlp was last asked again because the streams it named failed.
    var refreshedAt: ContinuousClock.Instant?
    /// The streams that failed to play since yt-dlp was last asked, which the picker leaves out.
    var failed: Set<String> = []
    /// Waits for the site to start serving the chosen streams.
    var loadTask: Task<Void, Never>?
    var sponsorTask: Task<Void, Never>?
    var subtitleTask: Task<Void, Never>?

    init(playback: WebPlayback) {
        self.playback = playback
    }
}

/// The player playing a video from the web: yt-dlp names the streams, the picker chooses the picture and the sound, mpv
/// plays them as one title, and the rest of the player (chapters, skips, menus, Stream Info, Match Content) reads them
/// through the same `ResolvedStream` a Plex title has. Progress is kept in the viewer's own library, never on a site.
extension PlayerScreen {
    func startWeb() {
        guard web != nil else { return }
        resolveWeb()
    }

    /// Asks yt-dlp for the video and plays it from `position` (by default the link's start or where the viewer left it).
    func resolveWeb(fresh: Bool = false, at position: Double? = nil, paused: Bool = false) {
        guard let web else { return }
        let address = web.playback.entry.url
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            do {
                let video = try await WebService.shared.video(address, fresh: fresh)
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.openWeb(video, at: position, paused: paused)
            } catch {
                guard let self, !Task.isCancelled, !self.closed else { return }
                MidgarLog.error("Reading a web video failed: \(error)", category: .playback)
                self.presentFailure(WebService.message(for: error), retry: { [weak self] in self?.resolveWeb(fresh: true, at: position, paused: paused) })
            }
        }
    }

    /// Chooses the video's streams and hands them to mpv. The first time, the storyboard, the subtitles on offer and
    /// SponsorBlock's stretches are set up too; later calls (another quality or language, a retry) keep those.
    func openWeb(_ video: WebVideo, at requested: Double?, paused: Bool) {
        guard let web else { return }
        if web.video == nil {
            web.subtitles = video.subtitles.filter { !$0.isAutomatic || $0.isOriginal }
            if !video.isLive, let loader = WebStoryboardLoader(video: video, window: window) {
                loader.onChange = { [weak self] in self?.transport.setNeedsDisplay() }
                web.stills = loader
                transport.still = { [weak loader] time in loader?.still(at: time) }
            }
            loadSponsorSegments(for: video)
            let entry = WebEntry(video)
            preroll?.update(title: entry.title, subtitle: entry.channel, posterPath: WebArtwork.url(entry.thumbnailCandidates)?.absoluteString)
            loadWebArtworkForMediaControls(entry)
        }
        web.video = video
        let preferences = WebService.shared.preferences(in: window, surround: !spdifCodecs.isEmpty, audioLanguage: web.audioLanguage, excluded: web.failed)
        guard let selection = WebFormatPicker.pick(from: video, preferences: preferences, quality: web.chosenQuality), let plan = WebPlaybackPlan(selection) else {
            presentFailure(String(localized: "yt-dlp found nothing to play in this video.", comment: "Web video error: no stream without protection"), retry: nil)
            return
        }
        web.selection = selection
        let start = video.isLive ? 0 : (requested ?? web.playback.start ?? WebService.shared.library.resumePosition(of: video.id))
        let resolved = webStream(of: video, selection: selection)
        stream = resolved
        segments = resolved.segments
        streamOffset = 0
        transport.title = video.title
        transport.chapterMarks = ChapterList.playable(resolved.chapters).map(\.startSecs)
        player?.set("sub-scale", String(format: "%.2f", Double(Preferences.subtitleSize.rawValue) / 100))
        player?.set("speed", String(speed))
        loadTweaks()
        applyDisplay()
        reapplyLoop()
        infoPanel?.update(infoContent)
        web.loadTask?.cancel()
        let wait = min(selection.readyAt?.timeIntervalSinceNow ?? 0, 10)
        guard wait > 0.05 else {
            load(plan, of: video, from: start, paused: paused)
            return
        }
        MidgarLog.notice("The site serves these streams in \(String(format: "%.1f", wait)) s; waiting", category: .playback)
        web.loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 200))
            guard let self, !Task.isCancelled, !self.closed else { return }
            self.load(plan, of: video, from: start, paused: paused)
        }
    }

    /// Hands the chosen streams to mpv.
    private func load(_ plan: WebPlaybackPlan, of video: WebVideo, from start: Double, paused: Bool) {
        player?.set("user-agent", plan.userAgent ?? WebArtwork.userAgent)
        player?.load(location: plan.location, start: start, headers: plan.headers)
        player?.setPaused(paused)
        if let window, let stream { MatchContent.engage(stream, in: window) }
        matchedFullscreen = window?.isFullscreen ?? false
        ScreenAwake.hold(true, in: window)
        let transport = plan.selection.video?.isProgressive == false ? "segments" : "one file"
        MidgarLog.notice("Playing a web video from \(video.site) at \(plan.selection.quality?.label ?? "sound only") (\(transport)) from \(Int(start)) s",
                         category: .playback)
    }

    /// Once mpv has the file open: the chosen subtitle is added again (a reload drops what was added beside the last
    /// one), and the frame rate mpv read from the file replaces the site's rounded one for Match Content.
    func settleWebTracks() {
        guard let web, let video = web.video, let selection = web.selection else { return }
        showWebSubtitle()
        guard let measured = player?.get("container-fps").flatMap(Double.init), measured > 0, let declared = selection.video?.frameRate,
              abs(measured - declared) > 0.005, abs(measured - declared) < 1 else { return }
        let corrected = webStream(of: video, selection: selection, frameRate: measured)
        stream = corrected
        if let window, window.isFullscreen, !isMini { MatchContent.engage(corrected, in: window) }
    }

    // MARK: The stream as the player reads it

    /// The video as the `ResolvedStream` the rest of the player works from: playing directly, with the site's chapters,
    /// SponsorBlock's stretches as skip markers, and the languages and subtitles on offer as streams.
    private func webStream(of video: WebVideo, selection: WebSelection, frameRate: Double? = nil) -> ResolvedStream {
        let languages = WebFormatPicker.audioLanguages(of: video)
        var audio: [PlexStream] = []
        var playing: Int?
        if languages.isEmpty {
            audio = [Self.audioStream(id: 1, format: selection.audio ?? selection.video, language: selection.audio?.language ?? video.language, original: false)].compactMap { $0 }
            playing = audio.first?.id
        } else {
            for (index, language) in languages.enumerated() {
                let isPlaying = language.code == selection.audio?.language
                if isPlaying { playing = index + 1 }
                if let stream = Self.audioStream(id: index + 1, format: isPlaying ? selection.audio : nil, language: language.code, original: language.isOriginal) {
                    audio.append(stream)
                }
            }
        }
        let subtitles = (web?.subtitles ?? []).enumerated().compactMap { Self.subtitleStream($1, id: $0 + 1) }
        let chapters = video.chapters.enumerated().map { index, chapter in
            PlexChapter(index: index + 1, tag: chapter.title, startTimeOffset: Int(chapter.start * 1000), endTimeOffset: Int(chapter.end * 1000), thumb: nil)
        }
        return ResolvedStream(url: URL(string: video.pageURL) ?? URL(fileURLWithPath: "/"), isDirectPlay: true, sessionId: "", subtitles: subtitles,
                              audioTracks: audio, markers: [], media: Self.media(of: selection, frameRate: frameRate), chapters: chapters,
                              chosenSubtitleId: web?.chosenSubtitle, chosenAudioStreamId: playing,
                              segments: (web?.sponsor ?? []).map(Self.marker))
    }

    /// Builds one of Core's server records from the fields it would decode, so web streams need no initializer of their
    /// own in the code the Apple apps share.
    private static func record<Record: Decodable>(_ type: Record.Type, _ fields: [String: Any]) -> Record? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Formatters.displayLocale.localizedString(forIdentifier: code) ?? code
    }

    private static func audioStream(id: Int, format: WebFormat?, language: String?, original: Bool) -> PlexStream? {
        var title = languageName(language) ?? String(localized: "Original", comment: "Web video audio track whose language the site does not say")
        if original { title = String(localized: "\(title), original", comment: "Web video audio track in the language the video was made in, as in \"English, original\"") }
        var fields: [String: Any] = ["id": id, "streamType": 2, "displayTitle": title]
        if let language { fields["languageTag"] = language }
        if let format {
            if let codec = format.audioFamily, codec != .other { fields["codec"] = codec.rawValue }
            if let channels = format.audioChannels { fields["channels"] = channels }
            if let bitrate = format.audioBitrate ?? (format.hasVideo ? nil : format.bitrate) { fields["bitrate"] = Int(bitrate) }
        }
        return record(PlexStream.self, fields)
    }

    private static func subtitleStream(_ subtitle: WebSubtitle, id: Int) -> PlexStream? {
        var title = languageName(subtitle.language) ?? subtitle.name ?? subtitle.language
        if subtitle.isAutomatic {
            title = String(localized: "\(title), auto-generated", comment: "Web video subtitle made by the site from the speech, as in \"English, auto-generated\"")
        }
        return record(PlexStream.self, ["id": id, "streamType": 3, "codec": subtitle.format, "languageTag": subtitle.language, "displayTitle": title, "key": "web"])
    }

    /// The chosen streams as a server's media record, which Stream Info and Match Content read the picture from.
    private static func media(of selection: WebSelection, frameRate: Double?) -> PlexMedia? {
        var fields: [String: Any] = ["id": 1]
        var streams: [[String: Any]] = []
        if let picture = selection.video, picture.videoCodec != nil {
            let codec = picture.videoFamily.flatMap { $0 == .other ? nil : $0.displayName } ?? picture.videoCodec ?? ""
            var video: [String: Any] = ["id": 1, "streamType": 1, "codec": codec]
            if let rate = frameRate ?? picture.frameRate { video["frameRate"] = rate }
            if picture.isHDR {
                video["colorTrc"] = picture.dynamicRange?.contains("HLG") == true ? "arib-std-b67" : "smpte2084"
                video["bitDepth"] = 10
            }
            streams.append(video)
            fields["videoCodec"] = codec
            if let width = picture.width { fields["width"] = width }
            if let height = picture.height { fields["height"] = height }
            if let container = picture.container { fields["container"] = container }
        }
        let rate = [selection.video, selection.audio].compactMap { $0?.bitrate }.reduce(0, +)
        if rate > 0 { fields["bitrate"] = Int(rate) }
        fields["Part"] = [["id": 1, "key": "", "Stream": streams]]
        return record(PlexMedia.self, fields)
    }

    // MARK: SponsorBlock

    private func loadSponsorSegments(for video: WebVideo) {
        web?.sponsorTask = Task { [weak self] in
            let found = await WebService.shared.sponsorSegments(for: video)
            guard let self, !Task.isCancelled, !self.closed, let web = self.web, !found.isEmpty else { return }
            web.sponsor = found
            self.segments = found.map(Self.marker)
            if let video = web.video, let selection = web.selection { self.stream = self.webStream(of: video, selection: selection) }
            MidgarLog.notice("SponsorBlock marks \(found.count) stretches of this video", category: .playback)
        }
    }

    /// A SponsorBlock stretch as the kind of skip marker nearest it: promotion of any kind is a commercial, and an
    /// outro is an ending, which is skipped like any stretch instead of handing over to Up Next as credits do.
    private static func marker(_ segment: SponsorBlock.Segment) -> SkipMarker {
        let kind: SkipMarker.Kind
        switch segment.category {
        case .sponsor, .selfPromotion, .interaction, .filler, .offTopicMusic: kind = .commercial
        case .intro: kind = .intro
        case .outro: kind = .ending
        case .preview, .hook: kind = .preview
        }
        return SkipMarker(kind: kind, startSecs: segment.start, endSecs: segment.end)
    }

    /// Whether `segment` is skipped on its own, offered or left alone: a Plex title's markers follow Skip Intro and Skip
    /// Credits, a web video's follow the SponsorBlock setting.
    func skipHandling(of segment: SkipMarker) -> (automatic: Bool, off: Bool) {
        guard web != nil else {
            return (segment.isCredits ? Preferences.skipOutroMode == .automatic : Preferences.skipIntroMode == .automatic,
                    segment.isCredits ? Preferences.skipOutroMode == .off : Preferences.skipIntroMode == .off)
        }
        return (WebSettings.sponsorMode == .automatic, WebSettings.sponsorMode == .off)
    }

    /// What the skip button says for `segment`: SponsorBlock's own name for a web video's stretch.
    func skipTitle(of segment: SkipMarker) -> String {
        guard let category = web?.sponsor.first(where: { $0.start == segment.startSecs && $0.end == segment.endSecs })?.category else { return segment.title }
        switch category {
        case .sponsor: return String(localized: "Skip Sponsor", comment: "Player button that jumps past a paid promotion in a web video")
        case .selfPromotion: return String(localized: "Skip Promotion", comment: "Player button that jumps past a channel promoting its own things")
        case .interaction: return String(localized: "Skip Reminder", comment: "Player button that jumps past a reminder to like and subscribe")
        case .outro: return String(localized: "Skip Outro", comment: "Player button that jumps past a web video's end cards")
        case .filler, .offTopicMusic: return String(localized: "Skip Ahead", comment: "Player button that jumps past a stretch off the video's subject")
        case .intro, .preview, .hook: return segment.title
        }
    }

    // MARK: Choices

    /// Another language to hear is another sound stream, so the video is opened again where it is; a subtitle is
    /// fetched and shown beside the picture.
    func chooseWeb(track id: Int?, audio: Bool) {
        guard let web, let video = web.video else { return }
        if audio {
            let languages = WebFormatPicker.audioLanguages(of: video)
            guard let id, languages.indices.contains(id - 1), languages[id - 1].code != web.selection?.audio?.language else { return }
            web.audioLanguage = languages[id - 1].code
            openWeb(video, at: position, paused: player?.state.isPaused ?? false)
            return
        }
        subtitlesTurnedOff = id == nil
        if let id { lastChosenSubtitle = id }
        borrowedSubtitle = nil
        web.chosenSubtitle = id
        showWebSubtitle()
        if let selection = web.selection { stream = webStream(of: video, selection: selection) }
        infoPanel?.update(infoContent)
    }

    /// Shows the chosen subtitle, fetching its file first, or none.
    private func showWebSubtitle() {
        guard let web, let video = web.video else { return }
        web.subtitleTask?.cancel()
        guard let id = web.chosenSubtitle, web.subtitles.indices.contains(id - 1) else {
            player?.setSubtitleTrack(nil)
            return
        }
        let subtitle = web.subtitles[id - 1]
        web.subtitleTask = Task { [weak self] in
            let file = await WebService.shared.subtitleFile(subtitle, of: video)
            guard let self, !Task.isCancelled, !self.closed, self.web?.chosenSubtitle == id else { return }
            guard let file else {
                self.say(String(localized: "Those subtitles couldn’t be loaded", comment: "Player message: a web video's subtitle file failed to download"),
                         symbol: "captions.bubble")
                return
            }
            self.player?.command(["sub-add", file.path, "cached", Self.languageName(subtitle.language) ?? subtitle.language, subtitle.language])
        }
    }

    /// Plays on in `quality`, or in what the picker chooses with nil.
    func setWebQuality(_ quality: WebQuality?) {
        guard let web, let video = web.video, web.chosenQuality != quality else { return }
        web.chosenQuality = quality
        openWeb(video, at: position, paused: player?.state.isPaused ?? false)
        let label = web.selection?.quality?.label ?? ""
        say(String(localized: "Quality \(label)", comment: "Player message after changing a web video's quality, as in \"Quality 1080p60\""), symbol: "sparkles.tv")
    }

    /// The Quality menu: Automatic with what it chose, then every quality the video has.
    func webQualityEntries() -> [ContextMenuView.Entry] {
        guard let web, let video = web.video else { return [] }
        let playing = web.selection?.quality
        var entries: [ContextMenuView.Entry] = [.action(ContextMenuView.Action(
            String(localized: "Automatic", comment: "Web video quality menu: Crucible picks"), detail: web.chosenQuality == nil ? playing?.label : nil,
            isChecked: web.chosenQuality == nil) { [weak self] in self?.setWebQuality(nil) })]
        entries.append(.separator)
        entries += WebFormatPicker.qualities(of: video).map { quality in
            .action(ContextMenuView.Action(quality.label, isChecked: web.chosenQuality == quality) { [weak self] in self?.setWebQuality(quality) })
        }
        return entries
    }

    /// The Quality row of the player's menu for a web video with more than one quality.
    func webQualitySubmenu() -> ContextMenuView.Entry? {
        guard let web, let video = web.video, WebFormatPicker.qualities(of: video).count > 1 else { return nil }
        return .submenu(String(localized: "Quality", comment: "Player menu: a web video's picture quality"), detail: web.selection?.quality?.label, symbol: "sparkles.tv") {
            [weak self] in self?.webQualityEntries() ?? []
        }
    }

    // MARK: Progress

    /// Keeps where the viewer is in the video, every ten seconds of it and when the player closes.
    func saveWebProgress(force: Bool = false) {
        guard let web, let video = web.video, !video.isLive, let state = player?.state, state.duration > 0, state.videoWidth > 0 || state.position > 1
        else { return }
        let now = position
        guard now > 1, force || abs(now - web.savedPosition) >= 10 else { return }
        web.savedPosition = now
        WebService.shared.library.record(WebEntry(video), position: now, duration: duration)
    }

    /// The web side of closing: the last position is kept, and a finished video is noted on its site when asked for.
    func closeWeb() {
        guard let web else { return }
        web.sponsorTask?.cancel()
        web.subtitleTask?.cancel()
        web.loadTask?.cancel()
        saveWebProgress(force: true)
        if let video = web.video, WebLibrary.isFinished(position: position, duration: duration) { WebService.shared.markWatched(video.pageURL) }
    }

    /// A stream that fails soon after yt-dlp read the video is one the site refuses: the next best stream plays in its
    /// place, since a site hands out the same picture in more than one way. One that fails later is most often an
    /// address that ran out, hours on: yt-dlp is asked again once and the video carries on where it was. A failure soon
    /// after that says so, with Retry.
    func recoverWeb(from message: String) {
        guard let web else { return }
        let at = stream == nil || position < 1 ? nil : position
        if let video = web.video, let refused = web.selection, web.failed.count < 4, let read = video.extracted, Date().timeIntervalSince(read) < 15 * 60 {
            web.failed.formUnion(refused.formats)
            let preferences = WebService.shared.preferences(in: window, surround: !spdifCodecs.isEmpty, audioLanguage: web.audioLanguage, excluded: web.failed)
            if WebFormatPicker.pick(from: video, preferences: preferences, quality: web.chosenQuality) != nil {
                MidgarLog.notice("A web stream failed (\(message)); playing the next best one", category: .playback)
                openWeb(video, at: at, paused: false)
                return
            }
        }
        web.failed = []
        if web.refreshedAt.map({ $0.duration(to: .now) > .seconds(60) }) ?? true {
            web.refreshedAt = .now
            MidgarLog.notice("A web stream failed (\(message)); asking yt-dlp again", category: .playback)
            resolveWeb(fresh: true, at: at)
            return
        }
        presentFailure(message, retry: { [weak self] in
            self?.web?.refreshedAt = .now
            self?.resolveWeb(fresh: true, at: at)
        })
    }

    /// Plays the next entry of the queue in this player's place; false when nothing is queued.
    func playNextWeb(byViewer: Bool) -> Bool {
        guard let web, let next = web.playback.queue.first, let hand = onPlayWeb else { return false }
        let following = WebPlayback(entry: next, start: nil, queue: Array(web.playback.queue.dropFirst()))
        let run = run.advancing(byViewer: byViewer, languages: nil, sleepTimer: sleepTimer)
        onClose = nil
        close()
        hand(following, run)
        return true
    }

    // MARK: Info and artwork

    /// What the info panel shows for a web video: its channel, when it was published and how often it was watched, its
    /// description, its chapters, and how it reaches the screen.
    var webInfoContent: PlayerInfoPanel.Content {
        let entry = web?.video.map(WebEntry.init) ?? web?.playback.entry
        var lines: [StreamInfoLine] = []
        if let video = web?.video {
            lines.append(StreamInfoLine(label: String(localized: "Source", comment: "Stream Info label: the site a web video comes from"),
                                        value: String(localized: "\(WebFormatting.siteName(video.site)), through yt-dlp",
                                                      comment: "Stream Info: the site and the open-source tool that reads it, as in \"YouTube, through yt-dlp\"")))
        }
        if let stream {
            lines += StreamInfo.lines(stream: stream, route: HomeServerRoute.classify(stream.url), quality: QualityPolicy.current(for: stream.url),
                                      audioId: stream.chosenAudioStreamId, subtitleId: stream.chosenSubtitleId).dropFirst(2)
        }
        return PlayerInfoPanel.Content(title: entry?.title ?? transport.title, subtitle: entry?.channel, summary: web?.video?.summary,
                                       facts: entry.flatMap(WebFormatting.facts), posterPath: entry.flatMap { WebArtwork.url($0.thumbnailCandidates)?.absoluteString },
                                       posterIsLandscape: true, chapters: ChapterList.playable(stream?.chapters ?? []), streamLines: lines,
                                       liveLines: livePlaybackLines, deliveryLines: liveDeliveryLines, bitrates: bitrateHistory)
    }

    /// Saves the thumbnail where the desktop's media controls can read it, keeping only the one playing.
    private func loadWebArtworkForMediaControls(_ entry: WebEntry) {
        guard let url = WebArtwork.url(entry.thumbnailCandidates) else { return }
        let directory = AppPlatform.cachesDirectory.appendingPathComponent("media-controls", isDirectory: true)
        let file = directory.appendingPathComponent("web-\(entry.id.filter { $0.isLetter || $0.isNumber }).jpg")
        Task { [weak self] in
            guard let data = try? await WebArtwork.fetch(url) else { return }
            let saved = await Task.detached(priority: .utility) { () -> Bool in
                try? FileManager.default.removeItem(at: directory)
                guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return false }
                return (try? data.write(to: file, options: .atomic)) != nil
            }.value
            guard saved, let self, !self.closed else { return }
            self.artworkFile = file
        }
    }
}
