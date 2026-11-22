import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The Shorts player's clips and what the viewer does with them: which clip each of its few players holds, what its
/// pages and rail say, and its actions.
extension WebShortsScreen {
    // MARK: Players

    /// The pane's size in the window's pixels, which the picture fetched for a clip is chosen for.
    private var panePixels: (width: Int, height: Int) {
        let pane = stage.pane
        let scale = window?.scale ?? 1
        return (Int((pane.width * scale).rounded()), Int((pane.height * scale).rounded()))
    }

    /// Gives the clip the feed landed on a player and plays it. A clip that was held ready plays at once; any other is
    /// opened a moment later, so skimming past clips asks yt-dlp for none of them.
    func land() {
        guard let window, !closed, let entry = current else { return }
        landing?.cancel()
        let kept = WebShorts.kept(around: index, count: entries.count)
        for slot in slots where slot.index.map({ !kept.contains($0) }) ?? false { slot.clear() }
        if let slot = currentSlot {
            slot.plays = !isPaused
            if slot.phase == .idle { slot.open(in: window, pane: panePixels) }
            holdNextReady()
        } else if let slot = freeSlot() {
            let first = slots.allSatisfy { $0.phase == .idle }
            slot.assign(entry, at: index)
            slot.plays = true
            let pane = panePixels
            landing = Task { [weak self, weak slot, weak window] in
                if !first { try? await Task.sleep(for: .milliseconds(320)) }
                guard let self, let slot, let window, !Task.isCancelled, !self.closed, slot.index == self.index, slot.phase == .idle else { return }
                slot.open(in: window, pane: pane)
            }
        }
        placePages()
    }

    /// Opens the clip after the one playing and holds it at its first frame, once the one playing is open.
    func holdNextReady() {
        guard let window, !closed, let playing = currentSlot, playing.phase != .idle, playing.phase != .resolving, playing.phase != .opening else { return }
        let target = index + 1
        guard entries.indices.contains(target), !slots.contains(where: { $0.index == target }), let slot = freeSlot() else { return }
        slot.assign(entries[target], at: target)
        slot.open(in: window, pane: panePixels)
        placePages()
        prepareSpare()
    }

    /// Makes the third player while the feed rests, so the first swipe that needs it does not wait on mpv starting up.
    private func prepareSpare() {
        guard slots.count < 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.slots.count < 3, !self.offset.isAnimating, let window = self.window, let loop = window.loop,
                      let spare = try? WebShortSlot(gpu: window.gpu, loop: loop) else { return }
                self.wire(spare)
                self.slots.append(spare)
            }
        }
    }

    /// A player with no clip to hold: an idle one, a new one while there are fewer than three, else the one holding the
    /// clip before the one playing.
    private func freeSlot() -> WebShortSlot? {
        if let idle = slots.first(where: { $0.index == nil }) { return idle }
        if slots.count < 3, let window, let loop = window.loop {
            do {
                let slot = try WebShortSlot(gpu: window.gpu, loop: loop)
                wire(slot)
                slots.append(slot)
                return slot
            } catch {
                MidgarLog.error("A Shorts player could not be made: \(error)", category: .playback)
            }
        }
        guard let spare = slots.first(where: { $0.index != index && $0.index != index + 1 }) else { return nil }
        spare.clear()
        return spare
    }

    func wire(_ slot: WebShortSlot) {
        slot.repeats = WebSettings.shortsAutoScroll == 0
        slot.speed = WebSettings.shortsSpeed
        slot.player.setVolume(WebSettings.shortsVolume)
        slot.setMuted(WebSettings.shortsMuted)
        slot.onChange = { [weak self] slot in self?.changed(slot) }
        slot.onResolved = { [weak self] slot, video in self?.resolved(video, in: slot) }
        slot.onEnded = { [weak self] slot in self?.ended(slot) }
        slot.onFrame = { [weak self] slot in self?.takesFrame(of: slot) ?? false }
    }

    /// Whether the clip `slot` holds has a page on screen, which then draws the waiting frame.
    private func takesFrame(of slot: WebShortSlot) -> Bool {
        guard window != nil, let number = slot.index, let page = pages[number], page.frame.intersects(bounds),
              !(feedMoves && !slot.hasPicture) else { return false }
        page.setNeedsDisplay()
        return true
    }

    private func changed(_ slot: WebShortSlot) {
        guard !closed, let number = slot.index else { return }
        let seen = Seen(phase: slot.phase, buffers: slot.player.state.isBuffering, shows: slot.hasPicture)
        if seenStates[ObjectIdentifier(slot)] != seen {
            seenStates[ObjectIdentifier(slot)] = seen
            pages[number]?.refresh()
        } else {
            pages[number]?.setNeedsDisplay()
        }
        guard number == index else { return }
        noteWatched()
        holdNextReady()
    }

    /// What yt-dlp said of a clip fills in what its list left out, and a lone clip's channel is asked for its others.
    private func resolved(_ video: WebVideo, in slot: WebShortSlot) {
        guard let number = slot.index, entries.indices.contains(number) else { return }
        videos[entries[number].id] = video
        var entry = entries[number]
        if entry.title.isEmpty { entry.title = video.title }
        entry.channel = entry.channel ?? video.channel
        entry.channelID = entry.channelID ?? video.channelID
        entry.channelURL = entry.channelURL ?? video.channelURL
        entry.duration = entry.duration ?? video.duration
        entry.viewCount = video.viewCount ?? entry.viewCount
        entry.published = entry.published ?? video.published
        entries[number] = entry
        pages[number]?.content = content(for: number)
        if number == index {
            refreshChrome()
            if detailsShown.target == 1 { showDetailsContent(rewinding: false) }
        }
        if followsWithChannel, number == index { followWithChannel(of: entry) }
    }

    /// The clip came to its end: the next one plays when the viewer asked for that, and the last one starts over.
    /// The clip came to its end: with Auto Scroll on, the next one plays once this one has played as often as it says;
    /// otherwise, and after the last clip, it starts over.
    private func ended(_ slot: WebShortSlot) {
        guard slot.index == index, !closed else { return }
        noteWatched(ended: true)
        plays += 1
        let after = WebSettings.shortsAutoScroll
        if after > 0, plays >= after, index < entries.count - 1 {
            show(index + 1)
        } else {
            slot.seek(to: 0)
            slot.player.setPausedLater(isPaused)
        }
    }

    /// Notes a clip watched most of the way in the viewer's own history, once.
    func noteWatched(ended: Bool = false) {
        guard let entry = current, !noted.contains(entry.id), let state = currentSlot?.player.state, state.duration > 0,
              ended || WebShorts.isWatched(position: state.position, duration: state.duration) else { return }
        noted.insert(entry.id)
        WebService.shared.library.record(entry, position: state.duration, duration: state.duration)
        WebService.shared.markWatched(entry.url)
    }

    /// Reads the Shorts of a lone clip's channel and puts them after it.
    private func followWithChannel(of entry: WebEntry) {
        guard channelTask == nil, let address = entry.channelURL ?? entry.channelID.map({ "https://www.youtube.com/channel/\($0)" }) else { return }
        let root = address.hasSuffix("/") ? String(address.dropLast()) : address
        channelTask = Task { [weak self] in
            guard let listing = try? await WebService.shared.listing("\(root)/shorts", limit: 60) else { return }
            guard let self, !Task.isCancelled, !self.closed else { return }
            if let id = listing.channelID ?? entry.channelID, let avatar = listing.avatar { self.avatars[id] = avatar }
            self.entries = WebShorts.extended(self.entries, with: listing.entries)
            if self.source == nil { self.source = listing.channel ?? entry.channel }
            for number in self.pages.keys { self.pages[number]?.content = self.content(for: number) }
            self.holdNextReady()
            self.setNeedsLayout()
            self.setNeedsDisplay()
        }
    }

    // MARK: What the pages and the rail say

    func content(for number: Int) -> WebShortPage.Content {
        let entry = entries[number]
        let video = videos[entry.id]
        var facts: [String] = []
        if let likes = video?.likeCount, likes > 0 { facts.append(WebShortsCopy.likes(likes)) }
        if let known = WebFormatting.facts(entry) { facts.append(known) }
        let commentCount = video?.commentCount ?? 0
        return WebShortPage.Content(title: entry.title, channel: entry.channel, facts: facts.joined(separator: " · "),
                                    poster: WebArtwork.url(entry.shortThumbnailCandidates(sharp: true)).map(ArtworkSource.url),
                                    avatar: entry.channelID.flatMap { avatars[$0] }.flatMap(WebArtwork.source), canFollow: entry.channelID != nil,
                                    isFollowed: entry.channelID.map(WebService.shared.library.isSubscribed) ?? false,
                                    commentsLink: commentCount > 0 ? WebShortsCopy.commentsLink(commentCount) : nil)
    }

    /// Brings the pages, the rail and the header up to date with the playing clip and the viewer's library.
    func refreshChrome() {
        guard !closed else { return }
        for number in pages.keys { pages[number]?.content = content(for: number) }
        let library = WebService.shared.library
        let saved = current.map { library.isSavedForLater($0.id) } ?? false
        rail.later.isOn = saved
        rail.later.caption = saved ? WebShortsCopy.saved : WebShortsCopy.save
        let count = current.flatMap { videos[$0.id]?.commentCount } ?? 0
        rail.comments.caption = count > 0 ? Formatters.compactCount(count) : WebShortsCopy.comments
        rail.comments.isOn = detailsShown.target == 1
        rail.link.caption = WebShortsCopy.share
        rail.channel.caption = WebShortsCopy.channelCaption
        let muted = WebSettings.shortsMuted
        rail.sound.symbol = muted ? "speaker.slash" : "speaker.wave.2"
        rail.sound.caption = muted ? WebShortsCopy.muted : WebShortsCopy.sound
        rail.speed.caption = PlayerScreen.speedTitle(WebSettings.shortsSpeed)
        rail.speed.isOn = abs(WebSettings.shortsSpeed - 1) > 0.01
        let after = WebSettings.shortsAutoScroll
        rail.auto.caption = after == 2 ? "\(WebShortsCopy.auto) ×2" : WebShortsCopy.auto
        rail.auto.isOn = after > 0
        rail.more.caption = WebShortsCopy.more
        previous.isOn = false
        setNeedsDisplay()
    }

    func wireRail() {
        rail.later.onPress = { [weak self] in self?.toggleLater() }
        rail.comments.onHover = { [weak self] in
            guard let self, let entry = self.current else { return }
            self.requestComments(for: entry)
        }
        rail.comments.onPress = { [weak self] in self?.setDetails(shown: self?.detailsShown.target == 0, focusing: self?.window?.isFocusVisible ?? false) }
        rail.link.onPress = { [weak self] in self?.copyLink() }
        rail.channel.onPress = { [weak self] in self?.openChannel() }
        rail.sound.onPress = { [weak self] in self?.toggleMute() }
        rail.sound.onWheel = { [weak self] notches in self?.changeVolume(by: Double(notches) * 5) }
        rail.speed.onPress = { [weak self] in
            guard let self else { return }
            self.presentSpeeds(at: self.rail.speed.frameInWindow)
        }
        rail.speed.onWheel = { [weak self] notches in self?.stepSpeed(notches > 0 ? 1 : -1) }
        rail.auto.onPress = { [weak self] in self?.cycleAutoScroll() }
        rail.auto.onContextMenu = { [weak self] in
            guard let self else { return }
            self.presentAutoScroll(at: self.rail.auto.frameInWindow)
        }
        rail.more.onPress = { [weak self] in
            guard let self else { return }
            let frame = self.rail.more.frameInWindow
            self.presentMenu(at: Point(x: frame.minX, y: frame.midY))
        }
    }

    // MARK: Actions

    func togglePause(quietly: Bool = false) {
        guard let slot = currentSlot else { return }
        isPaused.toggle()
        slot.plays = !isPaused
        currentPage?.isPaused = isPaused
        currentPage?.emphasizesBar = isPaused
        if !quietly, !isPaused { currentPage?.flash("play.fill") }
        if !quietly, isPaused { currentPage?.flash("pause.fill") }
        ScreenAwake.hold(!isPaused, in: window)
    }

    func retry() {
        guard let window, let slot = currentSlot else { return }
        slot.plays = !isPaused
        slot.retry(in: window)
    }

    /// Moves `seconds` through the clip, wrapping past its ends as the clip itself repeats.
    func seek(by seconds: Double, quietly: Bool = false) {
        guard let slot = currentSlot, slot.phase == .open else { return }
        let state = slot.player.state
        guard state.duration > 0 else { return }
        var target = state.position + seconds
        if target < 0 { target = seconds < -1 && state.position < 1 ? max(state.duration + target, 0) : 0 }
        if target >= state.duration { target = target - state.duration }
        slot.seek(to: target)
        if !quietly { currentPage?.flash(seconds < 0 ? "gobackward" : "forward.fill") }
    }

    func toggleMute() {
        WebSettings.shortsMuted.toggle()
        for slot in slots { slot.setMuted(WebSettings.shortsMuted) }
        refreshChrome()
        toast.show(WebSettings.shortsMuted ? WebShortsCopy.muted : WebShortsCopy.volume(Int(WebSettings.shortsVolume)),
                   symbol: WebSettings.shortsMuted ? "speaker.slash" : "speaker.wave.2")
    }

    func changeVolume(by amount: Double) {
        let volume = min(max(WebSettings.shortsVolume + amount, 0), 100)
        WebSettings.shortsVolume = volume
        WebSettings.shortsMuted = false
        for slot in slots {
            slot.setMuted(false)
            slot.player.setVolume(volume)
        }
        refreshChrome()
        toast.show(WebShortsCopy.volume(Int(volume)), symbol: volume == 0 ? "speaker.slash" : "speaker.wave.2")
    }

    func toggleLater() {
        guard let entry = current else { return }
        let library = WebService.shared.library
        if library.isSavedForLater(entry.id) {
            library.removeFromWatchLater(entry.id)
            toast.show(WebShortsCopy.removedFromLater, symbol: "bookmark.slash")
        } else {
            library.saveForLater(entry)
            currentPage?.flash("bookmark")
            toast.show(WebShortsCopy.savedForLater, symbol: "bookmark")
        }
    }

    func toggleFollow(at number: Int) {
        guard entries.indices.contains(number), let channelID = entries[number].channelID else { return }
        let entry = entries[number]
        let library = WebService.shared.library
        if library.isSubscribed(to: channelID) {
            library.unsubscribe(from: channelID)
        } else {
            library.subscribe(to: WebChannel(id: channelID, title: entry.channel ?? channelID, url: entry.channelURL, handle: videos[entry.id]?.channelHandle,
                                             avatar: avatars[channelID]))
        }
    }

    func copyLink() {
        guard let entry = current else { return }
        window?.copy(entry.url)
        toast.show(WebShortsCopy.linkCopied, symbol: "link")
    }

    func openChannel() {
        guard let entry = current, let root = rootView, entry.channelURL != nil || entry.channelID != nil else { return }
        close(animated: false)
        if RootView.showsWeb { root.select(RootView.webID) }
        WebActions.openChannel(of: entry, from: root)
    }

    /// Steps Auto Scroll on: off, after each play, after two plays, off again.
    func cycleAutoScroll() {
        setAutoScroll((WebSettings.shortsAutoScroll + 1) % 3)
    }

    func setAutoScroll(_ after: Int) {
        WebSettings.shortsAutoScroll = after
        for slot in slots { slot.repeats = after == 0 }
        toast.show(after == 0 ? WebShortsCopy.autoScrollOff : WebShortsCopy.autoScroll(after), symbol: after == 0 ? "repeat" : "arrow.down")
        refreshChrome()
    }

    /// Moves the speed `steps` places along the Shorts player's speeds, or back to normal for nil.
    func stepSpeed(_ steps: Int?) {
        let speeds = WebShortsCopy.speeds
        let now = speeds.firstIndex { abs($0 - WebSettings.shortsSpeed) < 0.01 } ?? speeds.firstIndex(of: 1) ?? 0
        setSpeed(steps.map { speeds[min(max(now + $0, 0), speeds.count - 1)] } ?? 1)
    }

    func setSpeed(_ value: Double) {
        WebSettings.shortsSpeed = value
        for slot in slots { slot.speed = value }
        toast.show(WebShortsCopy.speedMessage(value), symbol: "gauge.with.dots.needle.67percent")
        refreshChrome()
    }

    /// The speeds as a menu at `anchor`, the one playing checked.
    func presentSpeeds(at anchor: Rect) {
        guard let window else { return }
        let menu = MenuView(title: WebShortsCopy.speedName, items: WebShortsCopy.speeds.map { value in
            MenuView.Item(id: String(value), title: PlayerScreen.speedTitle(value), isChecked: abs(value - WebSettings.shortsSpeed) < 0.01)
        }, anchor: anchor)
        menu.onSelect = { [weak self] item in
            guard let value = Double(item.id) else { return }
            self?.setSpeed(value)
        }
        menu.present(in: window)
    }

    /// Auto Scroll's choices as a menu at `anchor`.
    func presentAutoScroll(at anchor: Rect) {
        guard let window else { return }
        let choices = [(0, String(localized: "Off")), (1, WebShortsCopy.afterEachPlay), (2, WebShortsCopy.afterTwoPlays)]
        let menu = MenuView(title: WebShortsCopy.autoScroll, items: choices.map { value, title in
            MenuView.Item(id: String(value), title: title, isChecked: WebSettings.shortsAutoScroll == value)
        }, anchor: anchor)
        menu.onSelect = { [weak self] item in
            guard let value = Int(item.id) else { return }
            self?.setAutoScroll(value)
        }
        menu.present(in: window)
    }

    /// Plays the clip in the full player from where it is, for its quality, subtitles and speed.
    func openInPlayer() {
        guard let entry = current, let root = rootView else { return }
        let position = currentSlot?.player.state.position
        close(animated: false)
        root.playWeb(WebPlayback(entry: entry, start: position, localPath: WebService.shared.library.download(of: entry.id)?.path))
    }

    // MARK: Description and comments

    /// Slides the details sheet in beside the clip or away; `focusing` puts the keyboard on it.
    /// `remembering` keeps the choice for the next time the Shorts player opens, where the window has room for the sheet.
    func setDetails(shown: Bool, focusing: Bool = false, remembering: Bool = true) {
        guard shown != (detailsShown.target == 1) else { return }
        if remembering { WebSettings.shortsShowsDetails = shown }
        detailsShown.set(shown ? 1 : 0, animation: .spring(response: 0.42, dampingFraction: 0.9))
        startAnimating()
        if shown {
            details.isHidden = false
            showDetailsContent(rewinding: true, waiting: false)
            if focusing { window?.focus.focus(details, animated: true) }
        } else if details.containsFocus {
            window?.focus.focus(self, animated: true)
        }
        refreshChrome()
    }

    /// Fills the sheet for the playing clip and its comments: at once when they were read already, else once the clip
    /// has stayed a moment (`waiting`, as the feed moves with the sheet open), so skimming past clips reads none.
    func showDetailsContent(rewinding: Bool, waiting: Bool = true) {
        guard let entry = current else { return }
        details.show(entry, video: videos[entry.id])
        if rewinding { details.rewind() }
        if let known = comments[entry.id], case .loaded = known {
            details.show(known)
            return
        }
        details.show(.loading)
        requestComments(for: entry, after: waiting ? .milliseconds(600) : .zero)
    }

    /// Reads `entry`'s top comments unless they were read or are on their way, as the pointer reaches what opens them, so
    /// the sheet opens on them already there.
    func requestComments(for entry: WebEntry, after delay: Duration = .zero) {
        if let known = comments[entry.id], case .loaded = known { return }
        if commentsFor == entry.id, commentsTask != nil { return }
        commentsTask?.cancel()
        commentsFor = entry.id
        commentsTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let outcome: WebShortsDetailsPanel.Comments
            do {
                outcome = .loaded(try await WebService.shared.videoWithComments(entry.url).comments.filter { $0.parentID == nil })
            } catch {
                outcome = .failed(WebService.message(for: error))
            }
            guard let self, !Task.isCancelled, !self.closed else { return }
            self.comments[entry.id] = outcome
            self.commentsTask = nil
            if self.current?.id == entry.id, self.detailsShown.target == 1 { self.details.show(outcome) }
        }
    }

    // MARK: Menu

    /// The clip's menu, at `point` of the window or by the More button.
    func presentMenu(at point: Point?) {
        guard let window, let entry = current else { return }
        let library = WebService.shared.library
        var items: [MenuView.Item] = [
            .init(id: "player", title: WebShortsCopy.openInPlayer, symbol: "play.rectangle"),
            .init(id: "auto", title: WebShortsCopy.autoScroll, detail: WebSettings.shortsAutoScroll == 0 ? String(localized: "Off") : WebShortsCopy.autoScrollDetail,
                  symbol: "arrow.down", shortcut: "A"),
            .init(id: "speed", title: WebShortsCopy.speedName, detail: PlayerScreen.speedTitle(WebSettings.shortsSpeed), symbol: "gauge.with.dots.needle.67percent",
                  shortcut: "[ ]"),
        ]
        let saved = library.isSavedForLater(entry.id)
        items.append(.init(id: "later", title: saved ? String(localized: "Remove from Watch Later", comment: "Web video menu") : WebCopy.watchLater,
                           symbol: saved ? "bookmark.slash" : "bookmark", shortcut: "S"))
        items.append(.init(id: "details", title: WebShortsCopy.details, symbol: "bubble.left", shortcut: "C"))
        if WebDownloads.shared.isRunning(entry.id) {
            items.append(.init(id: "download.cancel", title: WebDownloads.cancelTitle, symbol: "xmark.circle"))
        } else if library.download(of: entry.id) != nil {
            items.append(.init(id: "download.delete", title: WebDownloads.deleteTitle, symbol: "trash"))
        } else {
            items.append(.init(id: "download", title: WebDownloads.downloadTitle, symbol: "arrow.down.circle"))
        }
        if entry.channelURL != nil || entry.channelID != nil {
            items.append(.init(id: "channel", title: WebShortsCopy.goToChannel, symbol: "person.crop.circle", shortcut: "O"))
        }
        if let channelID = entry.channelID {
            let follows = library.isSubscribed(to: channelID)
            items.append(.init(id: "follow", title: follows ? String(localized: "Unfollow \(entry.channel ?? "")", comment: "Web video menu: stop following the video's channel")
                                                           : String(localized: "Follow \(entry.channel ?? "")", comment: "Web video menu: follow the video's channel"),
                               symbol: follows ? "xmark.circle" : "person.badge.plus"))
        }
        items.append(.init(id: "copy", title: WebShortsCopy.copyLink, symbol: "link", shortcut: KeyName.chord(KeyName.ctrl, "C")))
        items.append(.init(id: "browser", title: String(localized: "Open in Browser", comment: "Web video menu"), symbol: "globe"))
        let pane = transformToWindow.apply(stage.pane)
        let place = point ?? Point(x: pane.midX, y: pane.midY)
        let menu = MenuView(title: entry.title.isEmpty ? WebShortsCopy.title : entry.title, items: items, anchor: Rect(x: place.x, y: place.y, width: 1, height: 1))
        let number = index
        menu.onSelect = { [weak self] item in
            guard let self, !self.closed else { return }
            switch item.id {
            case "player": self.openInPlayer()
            case "auto": self.presentAutoScroll(at: Rect(x: place.x, y: place.y, width: 1, height: 1))
            case "speed": self.presentSpeeds(at: Rect(x: place.x, y: place.y, width: 1, height: 1))
            case "later": self.toggleLater()
            case "details": self.setDetails(shown: true, focusing: self.window?.isFocusVisible ?? false)
            case "download": WebDownloads.shared.start(entry, in: window)
            case "download.cancel": WebDownloads.shared.cancel(entry.id)
            case "download.delete": WebDownloads.shared.delete(entry.id)
            case "channel": self.openChannel()
            case "follow": self.toggleFollow(at: number)
            case "copy": self.copyLink()
            case "browser":
                if let url = URL(string: entry.url) { Browser.open(url) }
            default: break
            }
        }
        menu.present(in: window)
    }
}

/// What a Shorts player's page was last told of its clip, so it is told again only when that changed.
struct Seen: Equatable {
    var phase: WebShortSlot.Phase
    var buffers: Bool
    var shows: Bool
}
