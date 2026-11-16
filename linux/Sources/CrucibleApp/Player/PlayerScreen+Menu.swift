import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The player's right-click menu (`ContextMenuView`): playback and Go Back first, then Audio, Subtitles, Speed, Picture,
/// Chapters, Loop and Screenshot as submenus whose rows show what is set now, then the window and Close. Steppers and
/// toggles keep the menu open so a value can be tried in turn; a choice of track, speed or shape closes it.
extension PlayerScreen {
    /// Opens the menu at `point` (window points), or from the keyboard's Menu key over the transport.
    func presentContextMenu(at point: Point?) {
        guard let window, player != nil else { return }
        let origin = point ?? transport.transformToWindow.apply(Point(x: transport.bounds.midX, y: 0))
        let menu = ContextMenuView(at: origin, highlightingFirstRow: point == nil) { [weak self] in self?.menuEntries() ?? [] }
        menu.onDismiss = { [weak self] in
            self?.showChrome(autoHide: true)
            self?.contextMenu = nil
        }
        contextMenu = menu
        menu.present(in: window)
        showChrome(autoHide: false)
        holdChrome()
    }

    /// On a desk, a transport button opens the same menu as its row of the right-click menu, hanging from the button.
    func presentDeskMenu(for control: TransportView.Control, anchor: Rect) {
        guard let window, player != nil else { return }
        let entries: @MainActor () -> [ContextMenuView.Entry] = { [weak self] in
            guard let self else { return [] }
            switch control {
            case .audio: return self.audioEntries()
            case .subtitles: return self.subtitleEntries()
            case .speed: return self.speedEntries()
            case .sleep: return self.sleepEntries()
            case .info: return []
            }
        }
        contextMenu?.dismiss()
        let menu = ContextMenuView(anchor: anchor, entries: entries)
        menu.onDismiss = { [weak self] in
            self?.showChrome(autoHide: true)
            self?.contextMenu = nil
        }
        contextMenu = menu
        menu.present(in: window)
        showChrome(autoHide: false)
        holdChrome()
    }

    private func menuEntries() -> [ContextMenuView.Entry] {
        typealias Action = ContextMenuView.Action
        var entries: [ContextMenuView.Entry] = []
        let paused = player?.state.isPaused ?? true
        entries.append(.action(Action(paused ? String(localized: "Play", comment: "Player menu") : String(localized: "Pause", comment: "Player menu"),
                                      symbol: paused ? "play.fill" : "pause.fill", shortcut: KeyName.space) { [weak self] in self?.togglePause() }))
        let back = Preferences.skipBackSeconds
        let ahead = Preferences.skipForwardSeconds
        entries.append(.action(Action(String(localized: "Skip Back \(back) s", comment: "Player menu, with the skip distance"), shortcut: KeyName.left,
                                      keepsOpen: true) { [weak self] in
            guard let self else { return }
            self.seek(to: self.playhead - Double(back))
        }))
        entries.append(.action(Action(String(localized: "Skip Ahead \(ahead) s", comment: "Player menu, with the skip distance"), shortcut: KeyName.right,
                                      keepsOpen: true) { [weak self] in
            guard let self else { return }
            self.seek(to: self.playhead + Double(ahead))
        }))
        if let origin = jumpOrigin {
            entries.append(.action(Action(String(localized: "Go Back to \(TransportView.clock(origin))", comment: "Player menu: return to before the last jump"),
                                          symbol: "arrow.uturn.backward", shortcut: KeyName.chord(KeyName.shift, KeyName.backspace)) { [weak self] in
                self?.goBack()
            }))
        }
        if !skip.isHidden, let title = skip.title {
            entries.append(.action(Action(title, symbol: "forward.end.fill", shortcut: "S") { [weak self] in self?.skipSegment() }))
        }
        if isEpisode, upNext?.canOfferNext == true {
            entries.append(.action(Action(String(localized: "Next Episode", comment: "Player menu"), symbol: "forward.fill", shortcut: "N") { [weak self] in
                self?.offerNext(.requested)
            }))
        }
        entries.append(.separator)
        entries.append(audioSubmenu())
        entries.append(subtitleSubmenu())
        entries.append(.submenu(String(localized: "Speed", comment: "Player menu"), detail: Self.speedTitle(speed), symbol: "gauge.with.dots.needle.67percent") {
            [weak self] in self?.speedEntries() ?? []
        })
        entries.append(.submenu(String(localized: "Picture", comment: "Player menu"), symbol: "photo") { [weak self] in self?.pictureEntries() ?? [] })
        let chapters = ChapterList.playable(stream?.chapters ?? [])
        if !chapters.isEmpty {
            let current = ChapterList.current(chapters, at: position)
            entries.append(.submenu(String(localized: "Chapters", comment: "Player menu"), detail: current?.title, symbol: "list.bullet") {
                [weak self] in self?.chapterEntries() ?? []
            })
        }
        entries.append(.submenu(String(localized: "Loop", comment: "Player menu: A-B loop"), detail: loopDetail, symbol: "repeat") {
            [weak self] in self?.loopEntries() ?? []
        })
        entries.append(.submenu(String(localized: "Screenshot", comment: "Player menu"), symbol: "camera") { [weak self] in self?.screenshotEntries() ?? [] })
        entries.append(.submenu(SleepTimer.title, detail: sleepTimer?.menuTitle(isEpisode: isEpisode), symbol: "moon") {
            [weak self] in self?.sleepEntries() ?? []
        })
        entries.append(.separator)
        let fullscreen = window?.isFullscreen ?? false
        entries.append(.action(Action(String(localized: "Full Screen", comment: "Player menu"), shortcut: "F", isChecked: fullscreen) { [weak self] in
            guard let window = self?.window else { return }
            window.setFullscreen(!window.isFullscreen)
        }))
        if isMini {
            entries.append(.action(Action(String(localized: "Full Player", comment: "Mini player button: brings the full player back")) { [weak self] in
                self?.onExpand?()
            }))
        } else if onMinimize != nil {
            entries.append(.action(Action(String(localized: "Mini Player", comment: "Player button: keeps playing in a corner while you browse"), shortcut: "P") {
                [weak self] in self?.onMinimize?()
            }))
        }
        entries.append(.action(Action(String(localized: "Info", comment: "Player menu: the info panel"), shortcut: "I", isChecked: infoPanel != nil) {
            [weak self] in self?.toggleInfo()
        }))
        entries.append(.separator)
        entries.append(.action(Action(String(localized: "Close Player", comment: "Player menu"), shortcut: KeyName.esc) { [weak self] in self?.close() }))
        return entries
    }

    // MARK: Audio

    private func audioSubmenu() -> ContextMenuView.Entry {
        let current = stream.flatMap { stream in
            PlaybackTrackMenu.audioOptions(stream.audioTracks, selectedId: stream.chosenAudioStreamId).first { $0.isSelected }?.title
        }
        return .submenu(String(localized: "Audio", comment: "Player menu"), detail: current, symbol: "waveform") { [weak self] in self?.audioEntries() ?? [] }
    }

    func audioEntries() -> [ContextMenuView.Entry] {
        typealias Action = ContextMenuView.Action
        var entries: [ContextMenuView.Entry] = []
        if let stream {
            entries += PlaybackTrackMenu.audioOptions(stream.audioTracks, selectedId: stream.chosenAudioStreamId).map { option in
                .action(Action(option.title, detail: option.detail, isChecked: option.isSelected) { [weak self] in
                    self?.choose(track: option.id, audio: true)
                })
            }
            entries.append(.separator)
        }
        entries.append(.stepper(ContextMenuView.Stepper(String(localized: "Sync", comment: "Player menu: audio or subtitle delay"),
                                                        value: Self.syncValue(tweaks.title.audioDelay),
                                                        decrease: { [weak self] in self.map { $0.setAudioDelay($0.tweaks.title.audioDelay - 0.1) } },
                                                        increase: { [weak self] in self.map { $0.setAudioDelay($0.tweaks.title.audioDelay + 0.1) } },
                                                        reset: { [weak self] in self?.setAudioDelay(0) })))
        entries.append(.section(String(localized: "Dialogue", comment: "Player menu section")))
        for dialogue in PlayerTweaks.Dialogue.allCases {
            entries.append(.action(Action(Self.dialogueTitle(dialogue), detail: Self.dialogueDetail(dialogue), isChecked: tweaks.taste.dialogue == dialogue,
                                          keepsOpen: true) { [weak self] in self?.setDialogue(dialogue) }))
        }
        entries.append(.separator)
        entries.append(.action(Action(String(localized: "Volume Boost", comment: "Player menu: let the volume go past 100%"),
                                      detail: String(localized: "Up to 200%, with a limiter", comment: "Player menu: what Volume Boost does"),
                                      isChecked: tweaks.taste.volumeBoost, keepsOpen: true) { [weak self] in
            guard let self else { return }
            self.setVolumeBoost(!self.tweaks.taste.volumeBoost)
        }))
        return entries
    }

    static func dialogueDetail(_ dialogue: PlayerTweaks.Dialogue) -> String? {
        switch dialogue {
        case .off: nil
        case .clearSpeech: String(localized: "Voices lifted over music and effects", comment: "Player menu: what Clear Speech does")
        case .night: String(localized: "Loud scenes quieter, quiet ones louder", comment: "Player menu: what Night Mode does")
        }
    }

    // MARK: Subtitles

    private func subtitleSubmenu() -> ContextMenuView.Entry {
        let current = stream.flatMap { stream in
            PlaybackTrackMenu.subtitleOptions(stream.subtitles, selectedId: stream.chosenSubtitleId).first { $0.isSelected }?.title
        }
        return .submenu(String(localized: "Subtitles", comment: "Player menu"), detail: current, symbol: "captions.bubble") {
            [weak self] in self?.subtitleEntries() ?? []
        }
    }

    func subtitleEntries() -> [ContextMenuView.Entry] {
        typealias Action = ContextMenuView.Action
        var entries: [ContextMenuView.Entry] = []
        if let stream {
            entries += PlaybackTrackMenu.subtitleOptions(stream.subtitles, selectedId: stream.chosenSubtitleId).map { option in
                .action(Action(option.title, detail: option.detail, isChecked: option.isSelected) { [weak self] in
                    self?.choose(track: option.id, audio: false)
                })
            }
            entries.append(.separator)
        }
        entries.append(.stepper(ContextMenuView.Stepper(String(localized: "Sync", comment: "Player menu: audio or subtitle delay"),
                                                        value: Self.syncValue(tweaks.title.subtitleDelay),
                                                        decrease: { [weak self] in self.map { $0.setSubtitleDelay($0.tweaks.title.subtitleDelay - 0.1) } },
                                                        increase: { [weak self] in self.map { $0.setSubtitleDelay($0.tweaks.title.subtitleDelay + 0.1) } },
                                                        reset: { [weak self] in self?.setSubtitleDelay(0) })))
        entries.append(.stepper(ContextMenuView.Stepper(String(localized: "Position", comment: "Player menu: how high the subtitles sit"),
                                                        value: subtitleHeight,
                                                        decrease: { [weak self] in self?.moveSubtitles(by: -5) },
                                                        increase: { [weak self] in self?.moveSubtitles(by: 5) },
                                                        reset: { [weak self] in self.map { $0.moveSubtitles(by: $0.tweaks.taste.subtitlePosition - 100) } })))
        entries.append(.submenu(String(localized: "Size", comment: "Player menu: subtitle size"), detail: Preferences.subtitleSize.title) {
            SubtitleSize.allCases.map { size in
                .action(Action(size.title, isChecked: Preferences.subtitleSize == size, keepsOpen: true) { [weak self] in self?.setSubtitleSize(size) })
            }
        })
        entries.append(.submenu(String(localized: "Style", comment: "Player menu: subtitle look"), detail: Self.styleTitle(tweaks.taste.subtitleStyle)) {
            [weak self] in
            PlayerTweaks.SubtitleStyle.allCases.map { style in
                .action(Action(Self.styleTitle(style), isChecked: self?.tweaks.taste.subtitleStyle == style, keepsOpen: true) { [weak self] in
                    self?.setSubtitleStyle(style)
                })
            }
        })
        entries.append(.separator)
        entries.append(.action(Action(String(localized: "Show When Muted", comment: "Player menu: subtitles appear while the sound is muted"),
                                      isChecked: tweaks.taste.subtitlesWhenMuted, keepsOpen: true) { [weak self] in
            guard let self else { return }
            self.tweaks.taste.subtitlesWhenMuted.toggle()
            self.saveTaste()
        }))
        return entries
    }

    static func styleTitle(_ style: PlayerTweaks.SubtitleStyle) -> String {
        switch style {
        case .outline: String(localized: "Outline", comment: "Subtitle style")
        case .shadow: String(localized: "Drop Shadow", comment: "Subtitle style")
        case .box: String(localized: "Dark Box", comment: "Subtitle style")
        }
    }

    // MARK: Speed, picture, chapters, loop, screenshots, sleep

    func speedEntries() -> [ContextMenuView.Entry] {
        [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { value in
            .action(ContextMenuView.Action(Self.speedTitle(value), isChecked: abs(value - speed) < 0.01) { [weak self] in
                self?.setSpeed(value)
                self?.say(String(localized: "Speed \(Self.speedTitle(value))", comment: "Player message with the speed"), symbol: "gauge.with.dots.needle.67percent")
            })
        }
    }

    private func pictureEntries() -> [ContextMenuView.Entry] {
        typealias Action = ContextMenuView.Action
        var entries: [ContextMenuView.Entry] = []
        entries.append(.submenu(String(localized: "Shape", comment: "Player menu: the picture's framing"), detail: Self.framingTitle(tweaks.title.framing)) {
            [weak self] in
            PlayerTweaks.Framing.allCases.map { framing in
                .action(Action(Self.framingTitle(framing), isChecked: self?.tweaks.title.framing == framing) { [weak self] in self?.setFraming(framing) })
            }
        })
        entries.append(.stepper(ContextMenuView.Stepper(String(localized: "Zoom", comment: "Player menu"), value: zoomPercent,
                                                        decrease: { [weak self] in self?.zoom(by: -0.05) },
                                                        increase: { [weak self] in self?.zoom(by: 0.05) },
                                                        reset: { [weak self] in self.map { $0.zoom(by: -$0.tweaks.title.zoom) } })))
        entries.append(.stepper(ContextMenuView.Stepper(String(localized: "Rotate", comment: "Player menu: turn the picture a quarter"),
                                                        value: "\(tweaks.title.rotation)°",
                                                        decrease: { [weak self] in self?.rotate(by: -90) },
                                                        increase: { [weak self] in self?.rotate(by: 90) },
                                                        reset: { [weak self] in self.map { $0.rotate(by: -$0.tweaks.title.rotation) } })))
        entries.append(.action(Action(String(localized: "Deinterlace", comment: "Player menu"), isChecked: tweaks.title.deinterlace, keepsOpen: true) {
            [weak self] in self.map { $0.setDeinterlace(!$0.tweaks.title.deinterlace) }
        }))
        entries.append(.section(String(localized: "Adjust", comment: "Player menu section: picture adjustments")))
        for adjustment in Adjustment.allCases {
            let value = self.adjustment(adjustment)
            entries.append(.stepper(ContextMenuView.Stepper(adjustment.title, value: value == 0 ? "0" : (value > 0 ? "+\(value)" : "−\(-value)"),
                                                            decrease: { [weak self] in self.map { $0.setAdjustment(adjustment, to: $0.adjustment(adjustment) - 5) } },
                                                            increase: { [weak self] in self.map { $0.setAdjustment(adjustment, to: $0.adjustment(adjustment) + 5) } },
                                                            reset: { [weak self] in self?.setAdjustment(adjustment, to: 0) })))
        }
        entries.append(.separator)
        entries.append(.action(Action(String(localized: "Reset Picture", comment: "Player menu"), keepsOpen: true) { [weak self] in self?.resetPicture() }))
        entries.append(.action(Action(String(localized: "Calibrate Display…", comment: "Player menu: test patterns for black level and HDR peak"),
                                      detail: calibrationDetail) { [weak self] in self?.presentCalibration() }))
        return entries
    }

    /// What the picture is mapped to now, for the Calibrate Display row: "HDR, 4.0× white (calibrated)" or "SDR".
    private var calibrationDetail: String {
        guard let window else { return "" }
        let headroom = DisplayCalibrationStore.headroom(for: window)
        guard window.displayColor?.isHDR == true else { return String(localized: "SDR screen", comment: "Player menu: the screen shows SDR") }
        let value = String(format: "%.1f", headroom.value)
        return headroom.calibrated
            ? String(localized: "HDR, \(value)× white, calibrated", comment: "Player menu: HDR headroom the viewer measured")
            : String(localized: "HDR, \(value)× white, as reported", comment: "Player menu: HDR headroom the compositor reports")
    }

    private func chapterEntries() -> [ContextMenuView.Entry] {
        let chapters = ChapterList.playable(stream?.chapters ?? [])
        let current = ChapterList.current(chapters, at: position)
        return chapters.map { chapter in
            .action(ContextMenuView.Action(chapter.title, detail: TransportView.clock(chapter.startSecs), isChecked: chapter == current) {
                [weak self] in
                guard let self else { return }
                self.noteJump(from: self.position, to: chapter.startSecs)
                self.seek(to: chapter.startSecs)
            })
        }
    }

    private var loopDetail: String? {
        switch (loop.a, loop.b) {
        case (let a?, let b?): "\(TransportView.clock(a))–\(TransportView.clock(b))"
        case (let a?, nil): String(localized: "From \(TransportView.clock(a))", comment: "Player menu: loop start set, end not yet")
        default: nil
        }
    }

    private func loopEntries() -> [ContextMenuView.Entry] {
        typealias Action = ContextMenuView.Action
        let here = TransportView.clock(position)
        var entries: [ContextMenuView.Entry] = []
        if loop.a == nil {
            entries.append(.action(Action(String(localized: "Start Loop Here", comment: "Player menu"), detail: here, shortcut: "Shift+L") { [weak self] in
                self?.markLoop()
            }))
        } else if loop.b == nil {
            entries.append(.action(Action(String(localized: "End Loop Here", comment: "Player menu"), detail: here, shortcut: "Shift+L") { [weak self] in
                self?.markLoop()
            }))
        }
        if loop.a != nil {
            entries.append(.action(Action(String(localized: "Stop Looping", comment: "Player menu")) { [weak self] in self?.clearLoop() }))
        }
        return entries
    }

    private func screenshotEntries() -> [ContextMenuView.Entry] {
        typealias Action = ContextMenuView.Action
        return [
            .action(Action(String(localized: "Save Picture", comment: "Player menu: screenshot to a file"), detail: String(localized: "To Pictures/Crucible",
                                                                                                                   comment: "Player menu: where screenshots go"),
                           shortcut: "Shift+S") { [weak self] in self?.screenshot(withSubtitles: false, copy: false) }),
            .action(Action(String(localized: "Save Picture with Subtitles", comment: "Player menu")) { [weak self] in
                self?.screenshot(withSubtitles: true, copy: false)
            }),
            .action(Action(String(localized: "Copy Picture", comment: "Player menu: screenshot to the clipboard"), shortcut: KeyName.chord(KeyName.ctrl, "C")) {
                [weak self] in self?.screenshot(withSubtitles: false, copy: true)
            }),
        ]
    }

    func sleepEntries() -> [ContextMenuView.Entry] {
        let timer = sleepTimer
        var entries: [ContextMenuView.Entry] = [.action(ContextMenuView.Action(SleepTimer.off, isChecked: timer == nil) { [weak self] in
            self?.setSleepTimer(nil)
        })]
        entries += SleepTimerChoice.all.map { choice in
            .action(ContextMenuView.Action(choice.title(isEpisode: isEpisode), isChecked: timer?.choice == choice) { [weak self] in
                self?.setSleepTimer(choice)
            })
        }
        return entries
    }
}
