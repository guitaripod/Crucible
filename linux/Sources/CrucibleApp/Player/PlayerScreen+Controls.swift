import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The viewer's controls beyond the transport: Go Back, jumps by tenths, frame steps, sync, the subtitles' look, dialogue,
/// framing, picture, A-B Loop and screenshots, each saying on screen what it did, with what belongs to the title or to the
/// viewer kept for next time (`PlayerTweaks`).
extension PlayerScreen {
    // MARK: Jumps

    /// Whether a drag moves the picture with it: only when seeks on this file land fast enough to keep up.
    var dragMovesPicture: Bool {
        (player?.typicalSeekTime ?? .zero) < .milliseconds(250)
    }

    /// Covers the picture with the preview still for `target` until the seek there lands, so letting go of a drag shows
    /// where it went at once even when the picture takes most of a second to arrive.
    func veil(at target: Double) {
        guard let texture = stills?.still(at: target) else { return }
        let veil = seekVeil ?? {
            let view = StillVeil()
            insertSubview(view, at: 1)
            view.frame = bounds
            seekVeil = view
            return view
        }()
        veil.show(texture)
    }

    /// A jump at least this long (seconds) is worth Go Back.
    static let jumpWorthReturning: Double = 20

    /// Remembers where a long jump left from, for Go Back.
    func noteJump(from origin: Double, to target: Double) {
        guard abs(target - origin) >= Self.jumpWorthReturning else { return }
        jumpOrigin = origin
    }

    /// Returns to where the last long jump left from; doing it again returns to where Go Back was pressed.
    func goBack() {
        guard let origin = jumpOrigin else { return }
        let here = position
        seek(to: origin)
        jumpOrigin = here
        say(String(localized: "Back to \(TransportView.clock(origin))", comment: "Player message after Go Back, with the time returned to"),
            symbol: "arrow.uturn.backward")
    }

    /// Jumps to `tenth` tenths of the title, as the digit keys do.
    func jump(toTenth tenth: Int) {
        guard duration > 0 else { return }
        let target = duration * Double(tenth) / 10
        noteJump(from: position, to: target)
        seek(to: target)
    }

    func stepFrame(forward: Bool) {
        player?.frameStep(forward: forward)
        showChrome(autoHide: false)
    }

    /// A precise skip of `seconds`, for Shift with Left or Right.
    func nudge(by seconds: Double) {
        seek(to: playhead + seconds)
    }

    // MARK: Sync

    func setAudioDelay(_ value: Double) {
        tweaks.title.audioDelay = Self.sync(value)
        player?.set("audio-delay", String(format: "%.3f", tweaks.title.audioDelay))
        saveTitleTweaks()
        say(Self.syncMessage(String(localized: "Sound", comment: "Player sync message subject: the sound"), tweaks.title.audioDelay), symbol: "waveform", near: .audio)
    }

    func setSubtitleDelay(_ value: Double) {
        tweaks.title.subtitleDelay = Self.sync(value)
        player?.set("sub-delay", String(format: "%.3f", tweaks.title.subtitleDelay))
        saveTitleTweaks()
        say(Self.syncMessage(String(localized: "Subtitles", comment: "Player sync message subject: the subtitles"), tweaks.title.subtitleDelay),
            symbol: "captions.bubble", near: .subtitles)
    }

    /// A sync value rounded to milliseconds within ten seconds either way.
    static func sync(_ value: Double) -> Double {
        (min(max(value, -10), 10) * 1000).rounded() / 1000
    }

    /// "Sound 0.2 s later", "Subtitles 0.1 s earlier", "Sound in sync".
    static func syncMessage(_ subject: String, _ delay: Double) -> String {
        guard abs(delay) >= 0.0005 else {
            return String(localized: "\(subject) in sync", comment: "Player sync message when no delay is set, as in \"Sound in sync\"")
        }
        let amount = syncAmount(delay)
        return delay > 0
            ? String(localized: "\(subject) \(amount) later", comment: "Player sync message, as in \"Sound 0.2 s later\"")
            : String(localized: "\(subject) \(amount) earlier", comment: "Player sync message, as in \"Subtitles 0.1 s earlier\"")
    }

    /// A delay's size for a sync message or a menu value: "0.2 s", without its sign.
    static func syncAmount(_ delay: Double) -> String {
        let seconds = abs(delay).formatted(.number.precision(.fractionLength(abs(delay * 10).rounded() == abs(delay * 10) ? 1 : 2))
            .locale(Formatters.displayLocale))
        return String(localized: "\(seconds) s", comment: "A duration in seconds, as in \"0.2 s\"")
    }

    /// A delay for a stepper: "0", "+0.2 s" or "−0.1 s".
    static func syncValue(_ delay: Double) -> String {
        guard abs(delay) >= 0.0005 else { return "0" }
        return (delay > 0 ? "+" : "−") + syncAmount(delay)
    }

    // MARK: Subtitles

    func setSubtitleStyle(_ style: PlayerTweaks.SubtitleStyle) {
        tweaks.taste.subtitleStyle = style
        applySubtitleLook()
        saveTaste()
    }

    func moveSubtitles(by step: Int) {
        tweaks.taste.subtitlePosition = min(max(tweaks.taste.subtitlePosition - step, 50), 100)
        applySubtitleLook()
        saveTaste()
        let raised = 100 - tweaks.taste.subtitlePosition
        say(raised == 0
                ? String(localized: "Subtitles at the Bottom", comment: "Player message after moving the subtitles back down")
                : String(localized: "Subtitles \(raised)% Higher", comment: "Player message after moving the subtitles, with how much higher they sit"),
            symbol: "captions.bubble", near: .subtitles)
    }

    /// How far the subtitles sit above where the file puts them, for the stepper: "0" or "+10%".
    var subtitleHeight: String {
        let raised = 100 - tweaks.taste.subtitlePosition
        return raised == 0 ? "0" : "+\(raised)%"
    }

    func setSubtitleSize(_ size: SubtitleSize) {
        Preferences.subtitleSize = size
        player?.set("sub-scale", String(format: "%.2f", Double(size.rawValue) / 100))
        say(String(localized: "Subtitles \(size.title)", comment: "Player message after changing the subtitle size, as in \"Subtitles Large\""),
            symbol: "textformat.size", near: .subtitles)
    }

    /// Shows or hides the subtitles: the track chosen last comes back, or the one in the viewer's language.
    func toggleSubtitles() {
        guard let stream else { return }
        if borrowedSubtitle != nil {
            returnBorrowedSubtitle()
            say(String(localized: "Subtitles Off", comment: "Player message"), symbol: "captions.bubble", near: .subtitles)
        } else if stream.chosenSubtitleId != nil {
            choose(track: nil, audio: false)
            say(String(localized: "Subtitles Off", comment: "Player message"), symbol: "captions.bubble", near: .subtitles)
        } else if let pick = lastChosenSubtitle ?? captionChoice(in: stream)?.id {
            choose(track: pick, audio: false)
            let track = stream.subtitles.first { $0.id == pick }
            let title = track?.displayTitle ?? track?.language ?? ""
            say(String(localized: "Subtitles: \(title)", comment: "Player message after turning subtitles on, with the track"), symbol: "captions.bubble.fill", near: .subtitles)
        }
    }

    /// The text subtitle a viewer who needs one now most likely wants: one in the app's language, else the first full one.
    func captionChoice(in stream: ResolvedStream) -> PlexStream? {
        let language = Locale.preferredLanguages.first ?? "en"
        return StreamResolver.captionSubtitle(in: language, among: stream.subtitles)
            ?? stream.subtitles.first { !$0.isBitmap && $0.forced != true && $0.key == nil }
    }

    /// Shows a subtitle by itself, without choosing it, while the sound is muted, when the viewer turned that on and plays
    /// the file directly with no subtitle chosen.
    func borrowSubtitle() {
        guard borrowedSubtitle == nil, let stream, stream.isDirectPlay, stream.chosenSubtitleId == nil,
              let pick = captionChoice(in: stream), let track = FileTracks.subtitleTrack(pick.id, among: stream.subtitles) else { return }
        borrowedSubtitle = track
        player?.setSubtitleTrack(track)
    }

    func returnBorrowedSubtitle() {
        guard borrowedSubtitle != nil else { return }
        borrowedSubtitle = nil
        if stream?.chosenSubtitleId == nil { player?.setSubtitleTrack(nil) }
    }

    /// Follows the sound for the borrowed subtitle: muted shows it, unmuted takes it back.
    func followBorrowedSubtitle(muted: Bool) {
        if borrowedSubtitle != nil {
            if !muted { returnBorrowedSubtitle() }
        } else if muted, tweaks.taste.subtitlesWhenMuted {
            borrowSubtitle()
        }
    }

    // MARK: Sound

    func setDialogue(_ dialogue: PlayerTweaks.Dialogue) {
        tweaks.taste.dialogue = dialogue
        applyAudioFilters()
        saveTaste()
        say(Self.dialogueTitle(dialogue), symbol: "waveform", near: .audio)
    }

    static func dialogueTitle(_ dialogue: PlayerTweaks.Dialogue) -> String {
        switch dialogue {
        case .off: String(localized: "Dialogue as Mixed", comment: "Player sound option: no dialogue processing")
        case .clearSpeech: String(localized: "Clear Speech", comment: "Player sound option: speech lifted over music and effects")
        case .night: String(localized: "Night Mode", comment: "Player sound option: loud passages brought down")
        }
    }

    /// What `event` turns: the volume or the speed when a run of wheel notches or a touchpad glide began over the shown
    /// transport's volume slider, mute button or speed button, otherwise the seek. The run keeps what its first event chose
    /// until the fingers lift or the wheel rests half a second, so the transport fading out under a change, or a seek
    /// bringing it up under the pointer, never turns one into another halfway.
    func wheelTarget(for event: ScrollEvent) -> WheelTarget {
        guard !isMini else {
            wheelRun = nil
            return .seek
        }
        let now = Window.now()
        let target: WheelTarget
        if let wheelRun, now - wheelRun.at < 0.5 {
            target = wheelRun.target
        } else if transport.alpha > 0.01, let pointer = window?.pointerLocation {
            let local = transport.convert(pointer, from: nil)
            target = transport.turnsVolume(at: local) ? .volume : transport.turnsSpeed(at: local) ? .speed : .seek
        } else {
            target = .seek
        }
        wheelRun = event.ended ? nil : (target, now)
        return target
    }

    /// Steps the speed through the offered speeds by a wheel's notches or a touchpad's glide, one speed a notch.
    func turnSpeed(_ event: ScrollEvent) {
        let step = event.isDiscrete ? Double(-event.notchesY + event.notchesX) : Double(-event.dy + event.dx) * 0.05
        speedWheel += step
        let whole = Int(speedWheel.rounded(.towardZero))
        guard whole != 0 else { return }
        speedWheel -= Double(whole)
        stepSpeed(by: whole)
        say(Self.speedTitle(speed), symbol: "gauge.with.dots.needle.67percent", near: .speed)
    }

    /// Lets the volume go to 200%; the player brings a volume past 100% back to it when the boost goes off.
    func setVolumeBoost(_ on: Bool) {
        tweaks.taste.volumeBoost = on
        player?.maximumVolume = on ? 200 : 100
        applyAudioFilters()
        saveTaste()
        say(on ? String(localized: "Volume Boost On", comment: "Player message") : String(localized: "Volume Boost Off", comment: "Player message"),
            symbol: "speaker.wave.3", near: .volume)
    }

    /// The sound's filters: the dialogue chain, which the player follows with Volume Boost's gain and limiter while it is on.
    /// Any filter needs the sound decoded, so passthrough to a receiver pauses while one runs.
    func applyAudioFilters() {
        guard let player else { return }
        player.audioFilters = tweaks.taste.dialogue == .off ? [] : [tweaks.taste.dialogue.filter]
        player.set("audio-spdif", player.filtersSound ? "" : spdifCodecs.joined(separator: ","))
    }

    // MARK: Picture

    func setFraming(_ framing: PlayerTweaks.Framing) {
        tweaks.title.framing = framing
        applyFraming()
        saveTitleTweaks()
        say(Self.framingTitle(framing), symbol: "crop")
    }

    static func framingTitle(_ framing: PlayerTweaks.Framing) -> String {
        switch framing {
        case .original: String(localized: "Original Shape", comment: "Player framing: as the file is made")
        case .fill: String(localized: "Fill Screen", comment: "Player framing: cropped to fill the screen")
        case .stretch: String(localized: "Stretch", comment: "Player framing: stretched to the screen")
        case .wide, .standard, .scope: framing.aspect ?? ""
        }
    }

    func zoom(by step: Double) {
        tweaks.title.zoom = min(max(((tweaks.title.zoom + step) * 100).rounded() / 100, -1), 2)
        applyFraming()
        saveTitleTweaks()
        say(String(localized: "Zoom \(zoomPercent)", comment: "Player message with the zoom, as in \"Zoom 120%\""), symbol: "plus.magnifyingglass")
    }

    var zoomPercent: String { "\(Int((pow(2, tweaks.title.zoom) * 100).rounded()))%" }

    func rotate(by degrees: Int = 90) {
        tweaks.title.rotation = ((tweaks.title.rotation + degrees) % 360 + 360) % 360
        applyFraming()
        saveTitleTweaks()
        say(String(localized: "Rotated \(tweaks.title.rotation)°", comment: "Player message with the rotation"), symbol: "rotate.right")
    }

    func setDeinterlace(_ on: Bool) {
        tweaks.title.deinterlace = on
        player?.set("deinterlace", on ? "yes" : "no")
        saveTitleTweaks()
        say(on ? String(localized: "Deinterlacing On", comment: "Player message") : String(localized: "Deinterlacing Off", comment: "Player message"),
            symbol: "rectangle.split.3x1")
    }

    func applyFraming() {
        guard let player else { return }
        let title = tweaks.title
        player.set("video-aspect-override", title.framing.aspect ?? "no")
        player.set("panscan", title.framing == .fill ? "1.0" : "0.0")
        player.set("keepaspect", title.framing == .stretch ? "no" : "yes")
        player.set("video-zoom", String(format: "%.2f", title.zoom))
        player.set("video-rotate", String(title.rotation))
    }

    /// A picture adjustment: brightness, contrast, saturation or gamma, from −100 to 100.
    enum Adjustment: CaseIterable {
        case brightness, contrast, saturation, gamma

        var property: String {
            switch self {
            case .brightness: "brightness"
            case .contrast: "contrast"
            case .saturation: "saturation"
            case .gamma: "gamma"
            }
        }

        var title: String {
            switch self {
            case .brightness: String(localized: "Brightness", comment: "Player picture adjustment")
            case .contrast: String(localized: "Contrast", comment: "Player picture adjustment")
            case .saturation: String(localized: "Saturation", comment: "Player picture adjustment")
            case .gamma: String(localized: "Gamma", comment: "Player picture adjustment")
            }
        }
    }

    func adjustment(_ adjustment: Adjustment) -> Int {
        switch adjustment {
        case .brightness: tweaks.taste.brightness
        case .contrast: tweaks.taste.contrast
        case .saturation: tweaks.taste.saturation
        case .gamma: tweaks.taste.gamma
        }
    }

    func setAdjustment(_ adjustment: Adjustment, to value: Int) {
        let clamped = min(max(value, -100), 100)
        switch adjustment {
        case .brightness: tweaks.taste.brightness = clamped
        case .contrast: tweaks.taste.contrast = clamped
        case .saturation: tweaks.taste.saturation = clamped
        case .gamma: tweaks.taste.gamma = clamped
        }
        player?.set(adjustment.property, String(clamped))
        saveTaste()
    }

    func resetPicture() {
        Adjustment.allCases.forEach { setAdjustment($0, to: 0) }
        tweaks.title.zoom = 0
        tweaks.title.rotation = 0
        setFraming(.original)
        say(String(localized: "Picture Reset", comment: "Player message"), symbol: "arrow.counterclockwise")
    }

    // MARK: A-B Loop

    /// Sets the loop's start, then its end, then clears it, as one key does in turn.
    func markLoop() {
        guard let player else { return }
        let here = position
        if loop.a == nil {
            loop.a = here
            player.set("ab-loop-a", String(format: "%.3f", here - streamOffset))
            say(String(localized: "Loop from \(TransportView.clock(here))", comment: "Player message after setting the loop's start"), symbol: "repeat")
        } else if loop.b == nil, let a = loop.a, here > a + 0.5 {
            loop.b = here
            player.set("ab-loop-b", String(format: "%.3f", here - streamOffset))
            seek(to: a)
            say(String(localized: "Looping \(TransportView.clock(a))–\(TransportView.clock(here))", comment: "Player message once the loop is set"),
                symbol: "repeat")
        } else {
            clearLoop()
        }
    }

    /// Hands the loop to mpv again on its stream's timeline, after a converted stream was rebuilt from another place.
    func reapplyLoop() {
        guard let player else { return }
        player.set("ab-loop-a", loop.a.map { String(format: "%.3f", $0 - streamOffset) } ?? "no")
        player.set("ab-loop-b", loop.b.map { String(format: "%.3f", $0 - streamOffset) } ?? "no")
    }

    func clearLoop() {
        loop = (nil, nil)
        player?.set("ab-loop-a", "no")
        player?.set("ab-loop-b", "no")
        say(String(localized: "Loop Off", comment: "Player message"), symbol: "repeat")
    }

    // MARK: Screenshots

    /// Saves the picture on screen to Pictures/Crucible, or copies it, with or without the subtitles.
    func screenshot(withSubtitles: Bool, copy: Bool) {
        guard let player else { return }
        let name = Self.screenshotName(title: transport.title, at: position)
        let folder = copy ? AppPlatform.cachesDirectory : Self.picturesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        player.command(["screenshot-to-file", file.path, withSubtitles ? "subtitles" : "video"])
        if copy {
            Task { [weak self] in
                for _ in 0..<40 {
                    if let data = try? Data(contentsOf: file), !data.isEmpty {
                        self?.window?.copy(data, mimeType: "image/png")
                        try? FileManager.default.removeItem(at: file)
                        self?.say(String(localized: "Picture Copied", comment: "Player message after copying the picture"), symbol: "doc.on.doc")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } else {
            say(String(localized: "Saved to Pictures", comment: "Player message after saving a screenshot"), symbol: "camera")
        }
    }

    static func screenshotName(title: String, at seconds: Double) -> String {
        let safe = title.map { "/\\:".contains($0) ? "-" : $0 }
        return "\(String(safe)) \(TransportView.clock(seconds).replacingOccurrences(of: ":", with: "."))" + ".png"
    }

    /// The viewer's pictures folder from `user-dirs.dirs`, with Crucible's own folder in it.
    static var picturesFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        var pictures = home.appendingPathComponent("Pictures")
        if let dirs = try? String(contentsOf: config.appendingPathComponent("user-dirs.dirs"), encoding: .utf8),
           let line = dirs.split(separator: "\n").first(where: { $0.hasPrefix("XDG_PICTURES_DIR=") }) {
            let value = line.dropFirst("XDG_PICTURES_DIR=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            pictures = URL(fileURLWithPath: value.replacingOccurrences(of: "$HOME", with: home.path))
        }
        return pictures.appendingPathComponent("Crucible")
    }

    // MARK: Keeping and applying

    /// The key this title's settings are kept under.
    var tweakKey: String {
        switch source {
        case .plex(_, let item, _): PlayerTweakStore.key(ratingKey: item.id)
        case .file(let url, _): "file:" + url.path
        case .web(let playback): "web:" + playback.entry.id
        case .live(let session): "live:" + session.channel.id
        }
    }

    /// The key what holds for a whole show is kept under (Match Content, the volume): the show for an episode, otherwise
    /// the title itself.
    var showOrTitleKey: String {
        if case .plex(_, let item, _) = source, let show = item.grandparentRatingKey { return PlayerTweakStore.key(ratingKey: show) }
        return tweakKey
    }

    /// Whether Match Content acts for this title: on in Settings and turned on for this show or movie.
    var matchesContent: Bool {
        Preferences.matchesContent && titleRules.matchContent
    }

    func toggleMute() {
        guard let player else { return }
        let muting = !player.state.isMuted
        player.setMuted(muting)
        say(muting ? String(localized: "Mute") : String(localized: "Unmute", comment: "Player button: turn the sound back on"),
            symbol: muting ? "speaker.slash" : "speaker.wave.2", near: .volume)
    }

    /// Matches the screen to `stream` when Match Content is on for this title, and otherwise puts back what an earlier
    /// title in this sitting changed.
    func engageMatchContent(_ stream: ResolvedStream) {
        guard let window else { return }
        showHDR(MatchContent.isHDR(DynamicRange(file: stream.media?.Part?.first?.Stream), stream: stream))
        if matchesContent {
            MatchContent.engage(stream, in: window)
        } else {
            MatchContent.release()
        }
    }

    /// Tells the window whether HDR is showing, and maps the picture again for the output that follows from it.
    func showHDR(_ hdr: Bool) {
        guard let window, window.showsHDRContent != hdr else { return }
        window.showsHDRContent = hdr
        applyDisplay()
    }

    func setMatchContent(_ on: Bool) {
        changeTitleRules { $0.matchContent = on }
        if let stream, let window, window.isFullscreen, !isMini { engageMatchContent(stream) }
        say(on ? String(localized: "Match Content On", comment: "Player message") : String(localized: "Match Content Off", comment: "Player message"),
            symbol: "tv")
    }

    /// Sets the volume the viewer chose and keeps it for this show or movie, and as where a new one starts.
    func setViewerVolume(_ volume: Double) {
        guard let player else { return }
        if player.state.isMuted { player.setMuted(false) }
        player.setVolume(volume)
        PlayerVolumeStore.save(player.state.volume, for: showOrTitleKey)
    }

    /// Reads what the viewer set for this title and in general, and hands it to mpv before the file opens.
    func loadTweaks() {
        tweaks.title = PlayerTweakStore.title(tweakKey)
        tweaks.taste = PlayerTweakStore.taste()
        guard let player else { return }
        player.maximumVolume = tweaks.taste.volumeBoost ? 200 : 100
        if let volume = PlayerVolumeStore.volume(for: showOrTitleKey) { player.setVolume(volume) }
        player.set("audio-delay", String(format: "%.3f", tweaks.title.audioDelay))
        player.set("sub-delay", String(format: "%.3f", tweaks.title.subtitleDelay))
        player.set("deinterlace", tweaks.title.deinterlace ? "yes" : "no")
        Adjustment.allCases.forEach { player.set($0.property, String(adjustment($0))) }
        applyFraming()
        applySubtitleLook()
        applyAudioFilters()
    }

    func applySubtitleLook() {
        guard let player else { return }
        switch tweaks.taste.subtitleStyle {
        case .outline:
            player.set("sub-border-style", "outline-and-shadow")
            player.set("sub-border-size", "2.5")
            player.set("sub-shadow-offset", "1")
        case .shadow:
            player.set("sub-border-style", "outline-and-shadow")
            player.set("sub-border-size", "0.6")
            player.set("sub-shadow-offset", "2.5")
        case .box:
            player.set("sub-border-style", "background-box")
            player.set("sub-back-color", "#B3000000")
            player.set("sub-border-size", "3")
            player.set("sub-shadow-offset", "0")
        }
        placedSubtitlePosition = nil
        placeSubtitles()
    }

    /// Where the subtitles sit: where the viewer put them, lifted clear of the transport while it shows, as the Apple TV
    /// and streaming apps lift them over their controls.
    func placeSubtitles() {
        guard let player, bounds.height > 0 else { return }
        var position = tweaks.taste.subtitlePosition
        if chromeShown {
            let clear = (bounds.height - transport.frame.minY + Theme.current.metrics.tv(24)) / bounds.height * 100
            position = min(position, 100 - Int(clear.rounded(.up)))
        }
        guard position != placedSubtitlePosition else { return }
        placedSubtitlePosition = position
        player.set("sub-pos", String(max(position, 0)))
    }

    func saveTitleTweaks() {
        PlayerTweakStore.save(tweaks.title, for: tweakKey)
    }

    func saveTaste() {
        PlayerTweakStore.save(tweaks.taste)
    }

    // MARK: Feedback

    /// Says on the picture what an action did: above the transport's `near` control when the desk shows one, otherwise
    /// at the top.
    func say(_ message: String, symbol: Symbol? = nil, near: TransportView.Near? = nil) {
        toastNear = near
        let shown = toast ?? {
            let view = PlayerToast()
            addSubview(view)
            toast = view
            setNeedsLayout()
            return view
        }()
        shown.show(message, symbol: symbol)
        layoutToast()
    }

    func layoutToast() {
        guard let toast, let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        let size = toast.preferredSize(scale: scale)
        if !isMini, let near = toastNear, let anchor = transport.toastAnchor(near) {
            let x = min(max(transport.frame.x + anchor.midX - size.width / 2, metrics.tv(24)), bounds.width - size.width - metrics.tv(24))
            toast.frame = Rect(x: x.rounded(), y: transport.frame.y + anchor.y - size.height - metrics.tv(16), width: size.width, height: size.height)
        } else {
            toast.frame = Rect(x: 0, y: metrics.tv(48), width: bounds.width, height: size.height)
        }
        toast.setNeedsDisplay()
    }
}
