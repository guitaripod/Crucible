import CrucibleCore
import CrucibleUI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Kiln
import MidgarCore

/// The player's menus, info panel, sleep timer, breaks and what's next, on top of the playback in `PlayerScreen`.
extension PlayerScreen {
    /// The speeds the player offers, the Apple TV's own set.
    static let speeds: [Double] = [0.5, 1, 1.25, 1.5, 2]

    // MARK: Menus

    func present(_ control: TransportView.Control, anchor: Rect) {
        switch control {
        case .info: toggleInfo()
        case .speed: presentSpeeds(anchor: anchor)
        case .sleep: presentSleepTimer(anchor: anchor)
        case .audio: presentTracks(audio: true, anchor: anchor)
        case .subtitles: presentTracks(audio: false, anchor: anchor)
        }
    }

    private func presentMenu(_ title: String, items: [MenuView.Item], anchor: Rect, choose: @escaping (MenuView.Item) -> Void) {
        guard let window else { return }
        let menu = MenuView(title: title, items: items, anchor: anchor)
        menu.onSelect = { [weak self] item in
            self?.viewerActed()
            choose(item)
        }
        menu.onDismiss = { [weak self] in self?.showChrome(autoHide: true) }
        menu.present(in: window)
        showChrome(autoHide: false)
        holdChrome()
    }

    /// The Audio or Subtitles menu: the streams the server lists with the one playing checked (`PlaybackTrackMenu`).
    private func presentTracks(audio: Bool, anchor: Rect) {
        guard let stream else { return }
        let options = audio
            ? PlaybackTrackMenu.audioOptions(stream.audioTracks, selectedId: stream.chosenAudioStreamId)
            : PlaybackTrackMenu.subtitleOptions(stream.subtitles, selectedId: stream.chosenSubtitleId)
        let items = options.enumerated().map { index, option in
            MenuView.Item(id: option.id.map(String.init) ?? "off", title: option.title, detail: option.detail, isChecked: option.isSelected)
        }
        presentMenu(audio ? String(localized: "Audio") : String(localized: "Subtitles"), items: items, anchor: anchor) { [weak self] item in
            self?.choose(track: item.id == "off" ? nil : Int(item.id), audio: audio)
        }
    }

    /// A file playing directly switches in place; a converted stream is asked for again from where it is, with the new
    /// choice. A failed switch says so, with Retry. The show remembers the languages for its other episodes.
    func choose(track id: Int?, audio: Bool) {
        guard let stream, case .plex(let api, let item, _) = source else { return }
        if !audio { subtitlesTurnedOff = id == nil }
        if stream.isDirectPlay {
            switchInPlace(track: id, audio: audio, stream: stream)
            rememberLanguagesForShow()
            return
        }
        let resumeAt = position
        let subtitle = audio ? stream.chosenSubtitleId : id
        let audioId = audio ? id : stream.chosenAudioStreamId
        MidgarLog.notice("Switching streams ratingKey=\(item.id) audio=\(String(describing: audioId)) subtitle=\(String(describing: subtitle))",
                         category: .playback)
        let converts = convertsAfterFailure
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            do {
                let resolved = try await StreamResolver.resolve(api: api, ratingKey: item.id, startSecs: resumeAt, selectedSubtitleId: subtitle,
                                                                selectedAudioStreamId: audioId, forceTranscode: converts)
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.load(resolved, from: resumeAt)
                self.rememberLanguagesForShow()
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Switching tracks failed: \(error)", category: .playback)
                self?.presentFailure(ConnectionError.message(for: error), retry: { [weak self] in self?.choose(track: id, audio: audio) })
            }
        }
    }

    private func switchInPlace(track id: Int?, audio: Bool, stream: ResolvedStream) {
        let streams = audio ? stream.audioTracks : stream.subtitles
        if audio {
            if let index = streams.firstIndex(where: { $0.id == id }) { player?.setAudioTrack(index + 1) }
        } else if let id, let track = streams.first(where: { $0.id == id }) {
            if let key = track.key, var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false) {
                components.path = key
                components.query = nil
                guard let url = components.url else { return }
                player?.addSubtitle(url, title: track.displayTitle)
            } else {
                let embedded = streams.filter { $0.key == nil }
                if let index = embedded.firstIndex(where: { $0.id == id }) { player?.setSubtitleTrack(index + 1) }
            }
        } else {
            player?.setSubtitleTrack(nil)
        }
        self.stream = ResolvedStream(url: stream.url, isDirectPlay: true, sessionId: stream.sessionId, subtitles: stream.subtitles,
                                     audioTracks: stream.audioTracks, markers: stream.markers, media: stream.media, decision: stream.decision,
                                     chapters: stream.chapters, chosenSubtitleId: audio ? stream.chosenSubtitleId : id,
                                     chosenAudioStreamId: audio ? id : stream.chosenAudioStreamId, segments: stream.segments)
        infoPanel?.update(infoContent)
    }

    private func presentSpeeds(anchor: Rect) {
        let items = Self.speeds.map { value in
            MenuView.Item(id: String(value), title: Self.speedTitle(value), isChecked: abs(value - speed) < 0.01)
        }
        presentMenu(String(localized: "Playback Speed"), items: items, anchor: anchor) { [weak self] item in
            if let value = Double(item.id) { self?.setSpeed(value) }
        }
    }

    static func speedTitle(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)).locale(Formatters.displayLocale))
        return "\(number)×"
    }

    func setSpeed(_ value: Double) {
        speed = value
        player?.set("speed", String(value))
        transport.isSpeedChanged = abs(value - 1) > 0.01
    }

    /// The next speed up or down the list, for [ and ].
    func stepSpeed(by step: Int) {
        let index = Self.speeds.firstIndex { abs($0 - speed) < 0.01 } ?? 1
        setSpeed(Self.speeds[min(max(index + step, 0), Self.speeds.count - 1)])
    }

    /// The sleep timer: a few lengths of time or the end of what is playing, with the time left in the menu's title.
    private func presentSleepTimer(anchor: Rect) {
        let timer = sleepTimer
        var items = [MenuView.Item(id: "off", title: SleepTimer.off, isChecked: timer == nil)]
        items += SleepTimerChoice.all.enumerated().map { index, choice in
            MenuView.Item(id: String(index), title: choice.title(isEpisode: isEpisode), isChecked: timer?.choice == choice)
        }
        presentMenu(timer?.menuTitle(isEpisode: isEpisode) ?? SleepTimer.title, items: items, anchor: anchor) { [weak self] item in
            let choice = Int(item.id).flatMap { SleepTimerChoice.all.indices.contains($0) ? SleepTimerChoice.all[$0] : nil }
            self?.setSleepTimer(choice)
        }
    }

    func setSleepTimer(_ choice: SleepTimerChoice?) {
        restoreVolumeAfterFade()
        sleepTimer = choice.map { SleepTimer(choice: $0) }
        transport.isSleepTimerSet = sleepTimer != nil
        if let card, sleepTimer?.stopsAtEndOfItem == true { card.stopCounting() }
        MidgarLog.notice("Sleep timer \(choice.map { "\($0)" } ?? "off")", category: .playback)
    }

    // MARK: Chapters

    /// Page Up and Page Down: the start of this chapter (or the one before when it just began), or the next one.
    func moveByChapter(forward: Bool) {
        let chapters = ChapterList.playable(stream?.chapters ?? [])
        guard !chapters.isEmpty else { return }
        let now = position
        if forward {
            if let next = chapters.first(where: { $0.startSecs > now + 1 }) { seek(to: next.startSecs) }
            return
        }
        let current = ChapterList.current(chapters, at: now)
        if let current, now - current.startSecs > 3 {
            seek(to: current.startSecs)
        } else if let previous = chapters.last(where: { $0.startSecs < (current?.startSecs ?? now) - 0.5 }) {
            seek(to: previous.startSecs)
        } else {
            seek(to: 0)
        }
    }

    // MARK: Info

    func toggleInfo() {
        if infoPanel != nil {
            closeInfo()
            return
        }
        let panel = PlayerInfoPanel(content: infoContent)
        panel.onClose = { [weak self] in self?.closeInfo() }
        panel.onChapter = { [weak self] chapter in
            self?.seek(to: chapter.startSecs)
            self?.closeInfo()
        }
        infoPanel = panel
        addSubview(panel)
        setNeedsLayout()
        showChrome(autoHide: false)
        window?.focus.focus(panel, animated: false)
    }

    func closeInfo() {
        infoPanel?.removeFromSuperview()
        infoPanel = nil
        window?.focus.focus(self, animated: false)
        showChrome(autoHide: true)
    }

    /// What the info panel shows: the server's full record once it arrived, the card's until then.
    var infoContent: PlayerInfoPanel.Content {
        let headline = prerollHeadline
        guard case .plex(_, let item, _) = source else {
            return PlayerInfoPanel.Content(title: headline.title, chapters: [], streamLines: [])
        }
        let record = detail ?? item
        let genres = (record.Genre ?? []).compactMap(\.tag).prefix(3).joined(separator: ", ")
        let facts = [genres, item.grandparentTitle == nil ? nil : record.contentRating].compactMap { $0 }.filter { !$0.isEmpty }
        var lines = stream.map {
            StreamInfo.lines(stream: $0, route: HomeServerRoute.classify($0.url), quality: QualityPolicy.current(for: $0.url),
                             audioId: $0.chosenAudioStreamId, subtitleId: $0.chosenSubtitleId)
        } ?? []
        if convertsAfterFailure {
            lines.insert(StreamInfoLine(label: String(localized: "Direct Play", comment: "Stream Info: the file plays as it is"),
                                        value: String(localized: "Failed on this computer",
                                                      comment: "Linux Stream Info, beside Direct Play: playing the file as it is failed here, so the server converts it")), at: 1)
        }
        return PlayerInfoPanel.Content(title: item.title, subtitle: headline.subtitle, summary: record.summary,
                                       facts: facts.isEmpty ? nil : facts.joined(separator: " · "), posterPath: item.grandparentThumb ?? item.thumb,
                                       chapters: ChapterList.playable(stream?.chapters ?? []), streamLines: lines)
    }

    /// Reads the server's full record for the info panel: the synopsis, genres and rating.
    func loadInfo() {
        guard case .plex(let api, let item, _) = source else { return }
        metadataTask = Task { [weak self] in
            let record = try? await api.requestContainer(.metadata(ratingKey: item.id)).Metadata?.first
            guard let self, !Task.isCancelled, let record else { return }
            self.detail = record
            self.infoPanel?.update(self.infoContent)
        }
    }

    /// Shows the file's preview stills above the scrubber when the server has made them, keeping the ones already
    /// loaded when the same file is loaded again.
    func showStills(of resolved: ResolvedStream, api: APIClient) {
        guard let part = ScrubStills.part(of: resolved.media) else {
            stills = nil
            transport.still = nil
            return
        }
        guard stills?.partID != part.id else { return }
        let loader = ScrubStillLoader(partID: part.id, api: api, window: window)
        loader.onChange = { [weak self] in self?.transport.setNeedsDisplay() }
        stills = loader
        transport.still = { [weak loader] time in loader?.still(at: time) }
    }

    /// Saves the poster where the desktop's media controls can read it, keeping only the one playing.
    func loadArtworkForMediaControls() {
        guard case .plex(let api, let item, _) = source, let path = item.grandparentThumb ?? item.thumb,
              let url = Artwork.pipeline?.url(path: path, kind: .poster, pixelWidth: 600) else { return }
        let directory = AppPlatform.cachesDirectory.appendingPathComponent("media-controls", isDirectory: true)
        let file = directory.appendingPathComponent("\(item.id.filter { $0.isLetter || $0.isNumber }).jpg")
        let fetch = PlexArtworkPipeline.fetcher(token: api.token)
        Task { [weak self] in
            guard let data = try? await fetch(url) else { return }
            let saved = await Task.detached(priority: .utility) { () -> Bool in
                try? FileManager.default.removeItem(at: directory)
                guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return false }
                return (try? data.write(to: file, options: .atomic)) != nil
            }.value
            guard saved, let self, !self.closed else { return }
            self.artworkFile = file
        }
    }

    // MARK: Languages

    private var serverID: String { ServerBootstrap.savedMachineIdentifier ?? "unknown" }

    private var showKey: String? {
        if case .plex(_, let item, _) = source { return item.grandparentRatingKey }
        return nil
    }

    /// The languages a fresh start begins in: the episode before's, else the ones last chosen on the show.
    var startingLanguages: TrackLanguages? {
        run.trackLanguages ?? (isEpisode ? ShowTrackMemory.languages(forShow: showKey, server: serverID) : nil)
    }

    /// The audio and subtitle playing now, as languages the next episode can find among its own streams.
    var trackLanguages: TrackLanguages? {
        guard let stream else { return run.trackLanguages }
        return TrackLanguages(subtitleId: stream.chosenSubtitleId, audioStreamId: stream.chosenAudioStreamId, subtitles: stream.subtitles,
                              audioTracks: stream.audioTracks, subtitlesOff: subtitlesTurnedOff)
    }

    private func rememberLanguagesForShow() {
        guard isEpisode, let languages = trackLanguages else { return }
        ShowTrackMemory.remember(languages, forShow: showKey, server: serverID)
    }

    // MARK: Breaks and the sleep timer

    /// Whatever the viewer does at the keyboard, the pointer or the media keys: it ends a run of unattended episodes.
    func viewerActed() {
        run.viewerActedThisEpisode = true
    }

    /// One beat of the heartbeat: notices an absence, notes where the playhead is, and runs the sleep timer.
    func beat() {
        if let away = awayDetector.beat(at: .now), stream != nil {
            returnFromAway(away: away)
        } else if stream != nil, player?.state.isSeeking == false {
            positionAtLastBeat = position
        }
        checkSleepTimer()
    }

    /// Puts the player back after the machine slept (`PlaybackSession.returnFromAway`): a converted stream is rebuilt under a
    /// new server session, since the server reaped the old one, and a direct one is seeked; both are backed up when the viewer
    /// wants that. It plays on if it was playing and the absence was short, and stays paused after a long one.
    private func returnFromAway(away: Duration) {
        guard let player, let stream else { return }
        let snapshot = positionAtLastBeat
        let resumes = BreakRule.resumesPlaying(wasPlaying: !player.state.isPaused, away: away)
        let rewind = Preferences.rewindAfterBreak ? BreakRule.rewind(after: away) : 0
        let target = BreakRule.target(snapshot: snapshot, rewind: rewind, markers: segments)
        MidgarLog.notice("Playback returned away=\(away.components.seconds)s snapshot=\(Int(snapshot)) target=\(Int(target)) playing=\(resumes)",
                         category: .playback)
        if !resumes { player.setPaused(true) }
        positionAtLastBeat = target
        if stream.isDirectPlay {
            seek(to: target)
        } else {
            reloadStream(at: target, freshSession: true, paused: !resumes) { [weak self] in
                self?.presentFailure(String(localized: "The server didn’t answer."), retry: { [weak self] in
                    self?.reloadStream(at: target, freshSession: true)
                })
            }
        }
        report(resumes ? "playing" : "paused")
    }

    /// Notes when the viewer paused, and on playing again after a pause long enough to be a break backs up a little first
    /// (`BreakRule`); a converted stream the server may have reaped meanwhile is rebuilt under a new session.
    func notePause(_ isPaused: Bool) {
        if isPaused {
            if pausedSince == nil { pausedSince = .now }
            return
        }
        guard let since = pausedSince else { return }
        pausedSince = nil
        resumeAfterPause(since.duration(to: .now))
    }

    private func resumeAfterPause(_ pause: Duration) {
        guard let stream, preroll == nil else { return }
        let rewind = Preferences.rewindAfterBreak ? BreakRule.rewind(after: pause) : 0
        let gone = !stream.isDirectPlay && pause >= TranscodeLiveness.reapWindow
        guard rewind > 0 || gone else { return }
        let snapshot = position
        let target = BreakRule.target(snapshot: snapshot, rewind: rewind, markers: segments)
        MidgarLog.notice("Playing after a pause pause=\(pause.components.seconds)s position=\(Int(snapshot)) target=\(Int(target)) sessionGone=\(gone)",
                         category: .playback)
        if gone || (!stream.isDirectPlay && target < streamOffset) {
            reloadStream(at: target, freshSession: gone)
        } else {
            seek(to: target)
        }
    }

    /// Ends playback once the timer is due, whether or not anything plays; only sound that is playing fades out over the
    /// timer's last seconds.
    private func checkSleepTimer() {
        guard let timer = sleepTimer, let player else { return }
        let now = Date()
        if timer.isDue(now: now) {
            closeForSleep()
        } else if !player.state.isPaused, timer.startsFading(now: now), let remaining = timer.remaining(now: now) {
            if volumeBeforeFade == nil { volumeBeforeFade = player.state.volume }
            player.setVolume((volumeBeforeFade ?? 100) * remaining / SleepTimer.fadeSeconds)
        }
    }

    private func restoreVolumeAfterFade() {
        guard let volume = volumeBeforeFade else { return }
        player?.setVolume(volume)
        volumeBeforeFade = nil
    }

    /// The sleep timer ran out: playback pauses and the player closes, so the stream stops and the machine can sleep.
    func closeForSleep() {
        MidgarLog.notice("Sleep timer closing the player at \(Int(position)) s", category: .playback)
        sleepTimer = nil
        player?.setPaused(true)
        restoreVolumeAfterFade()
        close()
    }

    // MARK: What's next

    /// Once nothing plays next, titles like the one that ended take the screen over its last frame; without any, or with
    /// suggestions off, the player closes.
    func endOfPlayback() {
        guard postPlay == nil, !closed else { return }
        guard case .plex(let api, let item, _) = source else {
            close()
            return
        }
        if sleepTimer?.stopsAtEndOfItem == true {
            closeForSleep()
            return
        }
        let ended = PlaybackRequest(item: item, queue: run.queue)
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            let suggestions = await PostPlay.suggestions(for: ended, api: api)
            guard let self, !Task.isCancelled, !self.closed else { return }
            guard !suggestions.isEmpty else {
                self.close()
                return
            }
            self.showPostPlay(suggestions, heading: PostPlay.heading(for: ended))
        }
    }

    private func showPostPlay(_ suggestions: [PlexMetadata], heading: String) {
        let view = PostPlayView(heading: heading, items: suggestions)
        view.onPick = { [weak self] item in self?.playSuggestion(item) }
        view.onClose = { [weak self] in self?.close() }
        postPlay = view
        skip.isHidden = true
        transport.isHidden = true
        addSubview(view)
        setNeedsLayout()
        window?.focus.focus(view, animated: false)
        MidgarLog.notice("Post-play offered \(suggestions.count) titles", category: .playback)
    }

    /// A movie plays in this player's place; a show opens its page once the player has closed.
    private func playSuggestion(_ item: PlexMetadata) {
        viewerActed()
        MidgarLog.notice("Post-play picked ratingKey=\(item.id)", category: .playback)
        guard item.mediaType == "movie" else {
            let open = onOpenTitle
            close()
            open?(item)
            return
        }
        let next = run.advancing(byViewer: true, languages: nil, sleepTimer: sleepTimer)
        let hand = onPlayTitle
        onClose = nil
        close()
        hand?(item, next)
    }
}
