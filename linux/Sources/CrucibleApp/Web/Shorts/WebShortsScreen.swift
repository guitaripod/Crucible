import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The clips the Shorts player opens with.
struct WebShortsFeed {
    var entries: [WebEntry]
    /// The clip it opens on.
    var start = 0
    /// Where the clips come from, said under the title: a channel's name, or the followed channels.
    var source: String?
    /// A clip opened on its own (a link, a search result): its channel's other Shorts follow it.
    var followsWithChannel = false
}

/// The Shorts player: the feed as upright pages one above the other over the whole window, the one in the middle playing
/// and repeating, its neighbours peeking in above and below, with the next clip already open at its first frame so a
/// swipe shows it at once. The clip's own picture, blurred, washes the window behind it; its channel, title and facts lie
/// over its foot, and Watch Later, Comments, Copy Link, the channel, the sound and More stand in a rail beside it.
///
/// Mouse: the wheel or a two-finger swipe moves through the feed, as does a drag of the clip or a click above or below it;
/// a click pauses and plays, a double click fills the screen, a drag along the playhead scrubs, a right click opens the
/// menu. Keys: Up and Down (Page Up, Page Down, P and N) move through the feed, Space or K pauses, J and L (Left and
/// Right in the Desktop layout) move five seconds, Home starts the clip over, M mutes, Shift with Up and Down sets the
/// volume, S saves for later, C or I opens the description and comments, O the channel, A plays on by itself, F fills the
/// screen, Ctrl+C copies the link, Escape goes back. Gamepad: the d-pad or stick up and down and the shoulders move
/// through the feed, A pauses, Right reaches the rail, the triggers scrub, Y opens the menu, B goes back.
@MainActor
final class WebShortsScreen: View {
    /// Called once the player has closed and can be taken out of the window.
    var onClose: (() -> Void)?

    var entries: [WebEntry]
    var index: Int
    var source: String?
    var followsWithChannel: Bool

    let layer = View()
    let rail = WebShortsRail()
    let back = WebShortsRoundButton(symbol: "chevron.left", name: String(localized: "Back"), shortcut: KeyName.esc)
    let previous = WebShortsRoundButton(symbol: "chevron.up", name: WebShortsCopy.previous, shortcut: KeyName.up)
    let next = WebShortsRoundButton(symbol: "chevron.down", name: WebShortsCopy.next, shortcut: KeyName.down)
    let details = WebShortsDetailsPanel()
    let toast = PlayerToast()
    var pages: [Int: WebShortPage] = [:]

    /// Where the feed is drawn, in pages: the playing clip's place at rest, between two while it moves.
    var offset: Animated
    var pager = WebShortsPager()
    var detailsShown = Animated(0)
    var appearance = Animated(0)

    var slots: [WebShortSlot] = []
    var isPaused = false
    var videos: [String: WebVideo] = [:]
    var avatars: [String: String] = [:]
    var comments: [String: WebShortsDetailsPanel.Comments] = [:]
    var noted: Set<String> = []
    var seenStates: [ObjectIdentifier: Seen] = [:]
    /// How many times the playing clip has come to its end, for Auto Scroll.
    var plays = 0
    var landing: Task<Void, Never>?
    var commentsTask: Task<Void, Never>?
    /// The clip whose comments `commentsTask` reads.
    var commentsFor: String?
    var channelTask: Task<Void, Never>?
    var triggerScrub: Task<Void, Never>?
    var triggerPull: Float = 0
    var observer: NSObjectProtocol?
    var closed = false

    private struct Wash {
        let id: String
        let texture: Texture
        var opacity: Animated
    }

    private var washes: [Wash] = []
    /// The blur passes behind the washes, made once and taken in turn: making one is an allocation of a dozen GPU
    /// textures, which in the middle of a swipe cost a frame.
    private var washBlurs: [LiquidGlassRenderer] = []
    private var washTurn = 0
    private var washTask: Task<Void, Never>?
    private var press: (start: Point, dragging: Bool, last: Point)?
    private var scrub: (page: WebShortPage, resumes: Bool)?
    private var lastClickToggled = false
    private var holdTask: Task<Void, Never>?
    private var isFast = false
    private var begun = false

    init(feed: WebShortsFeed) {
        entries = feed.entries
        index = min(max(feed.start, 0), max(feed.entries.count - 1, 0))
        source = feed.source
        followsWithChannel = feed.followsWithChannel
        offset = Animated(Float(index))
        super.init()
        for channel in WebService.shared.library.subscriptions { avatars[channel.id] = channel.avatar }
        layer.clipsToBounds = false
        [layer, rail, back, previous, next, details, toast].forEach(addSubview)
        details.isHidden = true
        back.onPress = { [weak self] in self?.close() }
        previous.onPress = { [weak self] in self?.step(-1) }
        next.onPress = { [weak self] in self?.step(1) }
        details.onClose = { [weak self] in self?.setDetails(shown: false) }
        wireRail()
        observer = NotificationCenter.default.addObserver(forName: WebLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshChrome() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        tearDown()
    }

    override var canBecomeFocused: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { .default }
    override var preferredFocusView: View? { self }
    override var accessibilityLabel: String? { WebShortsCopy.title }

    /// How many of the rail's buttons fit beside the clip, whose height the pane takes most of the window's.
    var railCount: Int {
        WebShortsRail.count(fitting: bounds.height - 2 * max(Theme.current.metrics.tv(46), (bounds.height * 0.06).rounded()) - Theme.current.metrics.tv(48))
    }

    /// Whether the feed is moving: springing into place, or pulled by fingers or a drag.
    var feedMoves: Bool { offset.isAnimating || abs(offset.value - Float(index)) > 0.001 }

    var current: WebEntry? { entries.indices.contains(index) ? entries[index] : nil }
    var currentSlot: WebShortSlot? { slots.first { $0.index == index } }
    var currentPage: WebShortPage? { pages[index] }
    var usesDesk: Bool { Theme.current.density == .desk }

    override func didMoveToWindow() {
        begin()
    }

    /// Starts playing once the player is in a window and has its size, which the picture fetched for the first clip is
    /// chosen by: in a window with no size yet it waits for its first layout.
    private func begin() {
        guard window != nil, !closed, slots.isEmpty, !bounds.isEmpty, !begun else { return }
        begun = true
        appearance.set(1, animation: .timed(duration: 0.24, curve: .easeOut))
        startAnimating()
        ScreenAwake.hold(true, in: window)
        land()
        refreshChrome()
        showWash()
        if WebSettings.shortsShowsDetails, stage.panel.width >= Theme.current.metrics.tv(560), bounds.width >= Theme.current.metrics.tv(1500) {
            setDetails(shown: true, remembering: false)
        }
    }

    // MARK: Layout

    /// Where everything stands for the window's size and how far the details sheet is out.
    struct Stage {
        var pane: Rect
        var rail: Rect
        var railInside: Bool
        var panel: Rect
        /// From one page's top to the next one's.
        var pitch: Float
    }

    var stage: Stage {
        let metrics = Theme.current.metrics
        let margin = max(metrics.tv(46), (bounds.height * 0.06).rounded())
        let gap = metrics.tv(26)
        let railSize = WebShortsRail.size(count: railCount)
        var height = max(bounds.height - margin * 2, 1)
        var width = (height * 9 / 16).rounded()
        let outside = bounds.width >= width + 2 * (gap + railSize.width + metrics.tv(20))
        if !outside {
            width = min(width, max(bounds.width - metrics.tv(40), 1))
            height = min(height, (width * 16 / 9).rounded())
        }
        let shown = detailsShown.value
        let panelWidth = min(min(metrics.tv(820), max(bounds.width * 0.4, metrics.tv(560))), max(bounds.width - metrics.tv(48), 1))
        let panelX = bounds.maxX - metrics.tv(24) - panelWidth
        let trailing = bounds.midX + width / 2 + (outside ? gap + railSize.width : 0) + gap
        let room = bounds.midX - width / 2 - metrics.tv(24)
        let shift = max(0, min(trailing - panelX, room)) * shown
        let pane = Rect(x: (bounds.midX - width / 2 - shift).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        let railX = outside ? pane.maxX + gap : pane.maxX - railSize.width - metrics.tv(4)
        let railY = max(pane.maxY - railSize.height - metrics.tv(outside ? 4 : 44), pane.minY)
        let panel = Rect(x: (panelX + (1 - shown) * (panelWidth + metrics.tv(80))).rounded(), y: pane.y, width: panelWidth, height: pane.height)
        return Stage(pane: pane, rail: Rect(x: railX.rounded(), y: railY.rounded(), width: railSize.width, height: railSize.height), railInside: !outside,
                     panel: panel, pitch: height + metrics.tv(20))
    }

    override func layoutSubviews() {
        begin()
        let metrics = Theme.current.metrics
        let stage = stage
        layer.frame = bounds
        rail.count = railCount
        rail.frame = stage.rail
        let side = WebShortsRoundButton.diameter
        back.frame = Rect(x: metrics.tv(40), y: metrics.tv(40), width: side, height: side)
        let navX = bounds.maxX - metrics.tv(40) - side
        let showsNav = usesDesk && navX > stage.rail.maxX + metrics.tv(16)
        previous.isHidden = !showsNav
        next.isHidden = !showsNav
        previous.frame = Rect(x: navX, y: bounds.midY - side - metrics.tv(10), width: side, height: side)
        next.frame = Rect(x: navX, y: bounds.midY + metrics.tv(10), width: side, height: side)
        details.frame = stage.panel
        toast.frame = Rect(x: stage.pane.x, y: stage.pane.y + metrics.tv(36), width: stage.pane.width, height: metrics.tv(72))
        placePages(stage)
    }

    /// Makes the pages around the feed's place, puts each where the feed has it, and lets go of the ones gone by.
    func placePages(_ stage: Stage? = nil) {
        guard !entries.isEmpty else { return }
        let stage = stage ?? self.stage
        let place = offset.value
        let low = max(Int((place - 1.2).rounded(.down)), 0)
        let high = min(Int((place + 1.2).rounded(.up)), entries.count - 1)
        for (number, page) in pages where number < low || number > high {
            page.removeFromSuperview()
            pages[number] = nil
        }
        guard low <= high else { return }
        for number in low...high {
            let page = pages[number] ?? makePage(number)
            let away = Float(number) - place
            page.frame = Rect(x: stage.pane.x, y: (stage.pane.y + away * stage.pitch).rounded(), width: stage.pane.width, height: stage.pane.height)
            page.distance = abs(away)
            page.trailingInset = stage.railInside ? stage.rail.width : 0
            page.slot = slots.first { $0.index == number }
            page.isPaused = number == index && isPaused
            page.defersFirstFrame = feedMoves
        }
        let fade = 1 - detailsShown.value
        previous.alpha = fade
        next.alpha = fade
    }

    private func makePage(_ number: Int) -> WebShortPage {
        let page = WebShortPage(index: number)
        page.content = content(for: number)
        page.onFollow = { [weak self] in self?.toggleFollow(at: number) }
        page.onRetry = { [weak self] in self?.retry() }
        pages[number] = page
        layer.addSubview(page)
        return page
    }

    // MARK: Motion

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [offset.advance(dt), detailsShown.advance(dt), appearance.advance(dt)].contains(true)
        var fading = false
        for position in washes.indices where washes[position].opacity.advance(dt) { fading = true }
        if let top = washes.last, top.opacity.value >= 0.999, washes.count > 1 { washes.removeFirst(washes.count - 1) }
        alpha = closed ? appearance.value : max(appearance.value, 0.02)
        layer.scale = 0.96 + 0.04 * appearance.value
        if detailsShown.value <= 0.001, detailsShown.target == 0 { details.isHidden = true }
        setNeedsLayout()
        if closed, !moving {
            finishClosing()
            return false
        }
        return moving || fading
    }

    /// Moves `direction` clips through the feed, or gives a little at its ends.
    func step(_ direction: Int) {
        let target = index + direction
        guard entries.indices.contains(target) else {
            offset.reset(Float(index) + 0.0005 * Float(direction))
            offset.set(Float(index), animation: .spring(response: 0.42, dampingFraction: 0.5))
            offset.setVelocity(Float(direction) * 1.6)
            startAnimating()
            if direction > 0 { toast.show(WebShortsCopy.lastOne, symbol: "checkmark") }
            return
        }
        show(target)
    }

    /// Makes the clip at `target` the one playing and slides the feed to it.
    func show(_ target: Int) {
        guard entries.indices.contains(target), target != index else {
            settle()
            return
        }
        noteWatched()
        setFast(false)
        let left = currentSlot
        plays = 0
        index = target
        isPaused = false
        left?.plays = false
        left?.seek(to: 0)
        settle()
        land()
        refreshChrome()
        showWash()
        if detailsShown.target == 1 { showDetailsContent(rewinding: true) }
    }

    /// Springs the feed to the playing clip's place.
    private func settle() {
        offset.set(Float(index), animation: .spring(response: 0.44, dampingFraction: 0.86))
        startAnimating()
        setNeedsLayout()
    }

    // MARK: Drawing

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        context.fill(bounds, color: .black)
        for wash in washes { context.image(wash.texture, in: bounds, opacity: wash.opacity.value, srgb: true) }
        context.gradient(bounds, vertical: true, stops: [(0, Color.shade(0.8)), (0.3, Color.shade(0.62)), (0.7, Color.shade(0.62)), (1, Color.shade(0.82))])
        let stage = stage
        let x = back.frame.maxX + metrics.tv(24)
        let room = stage.pane.minX - x - metrics.tv(24)
        guard room > metrics.tv(180) else { return }
        let title = TextLayout(WebShortsCopy.title, font: theme.type.headline, maxWidth: room, maxLines: 1, scale: scale)
        var line = [source, entries.count > 1 ? "\(index + 1) / \(entries.count)" : nil].compactMap { $0 }.filter { !$0.isEmpty }
        if line.isEmpty, let channel = current?.channel { line = [channel] }
        let detail = TextLayout(line.joined(separator: " · "), font: theme.type.footnote, maxWidth: room, maxLines: 1, scale: scale)
        let height = title.size.height + metrics.tv(2) + detail.size.height
        let y = ((back.frame.midY - height / 2) * scale).rounded() / scale
        context.text(title, at: Point(x: x, y: y), color: theme.palette.onArt)
        context.text(detail, at: Point(x: x, y: y + title.size.height + metrics.tv(2)), color: theme.palette.onArtSecondary)
    }

    /// Washes the window with the playing clip's own picture, blurred, fading over the one before.
    func showWash() {
        guard let window, let images = window.images, let entry = current, washes.last?.id != entry.id,
              let url = WebArtwork.url(entry.shortThumbnailCandidates(sharp: false)) else { return }
        washTask?.cancel()
        washTask = Task { [weak self, weak window] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let texture = await images.load(ImageRequest(url: url, pixelWidth: 270, pixelHeight: 480)) else { return }
            guard let self, let window, !Task.isCancelled, !self.closed, self.current?.id == entry.id else { return }
            var opacity = Animated(0)
            opacity.set(1, animation: .timed(duration: 0.5, curve: .easeInOut))
            self.washes.append(Wash(id: entry.id, texture: self.blurred(texture, gpu: window.gpu) ?? texture, opacity: opacity))
            self.startAnimating()
        }
    }

    /// `texture` blurred by the next of three reusable blur passes, as many as washes can be fading at once.
    private func blurred(_ texture: Texture, gpu: GPU) -> Texture? {
        guard texture.width >= 16, texture.height >= 16 else { return nil }
        let turn = washTurn % 3
        washTurn += 1
        if washBlurs.count <= turn {
            guard let made = try? LiquidGlassRenderer(gpu: gpu, width: texture.width, height: texture.height) else { return nil }
            washBlurs.append(made)
        } else if washBlurs[turn].frost.width * 2 < texture.width - 1 || washBlurs[turn].frost.width * 2 > texture.width + 1 {
            guard (try? washBlurs[turn].resize(width: texture.width, height: texture.height)) != nil else { return nil }
        }
        washBlurs[turn].blur(texture, spread: 1.6)
        return washBlurs[turn].frost
    }

    // MARK: Keys

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard !closed else { return true }
        let mine = window?.focusedView === self
        let shift = event.modifiers == .shift
        let plain = event.modifiers.isEmpty
        if event.key == .escape || event.key == .back {
            if detailsShown.target == 1 {
                setDetails(shown: false)
            } else if !mine {
                window?.focus.focus(self, animated: true)
            } else {
                close()
            }
            return true
        }
        if event.clipboardCommand == .copy {
            copyLink()
            return true
        }
        guard plain || shift else { return false }
        switch event.key {
        case .up where shift, .down where shift:
            changeVolume(by: event.key == .up ? 5 : -5)
        case .up where mine, .pageUp, .tabPrevious:
            step(-1)
        case .down where mine, .pageDown, .tabNext:
            step(1)
        case .left where mine:
            if usesDesk { seek(by: -5) }
        case .left where rail.containsFocus:
            window?.focus.focus(self, animated: true)
        case .right where mine:
            if usesDesk { seek(by: 5) } else { window?.focus.focus(rail, animated: true) }
        case .return where mine, .keypadEnter where mine, .space where mine, .mediaPlay, .mediaPause:
            activate()
        case .backspace where plain:
            stepSpeed(nil)
        case .home where plain:
            currentSlot?.seek(to: 0)
        case .menu:
            presentMenu(at: nil)
        case .gamepadWest:
            setDetails(shown: detailsShown.target == 0, focusing: false)
        default:
            guard plain, let letter = event.typedText?.lowercased() else { return false }
            return handle(letter: letter)
        }
        return true
    }

    private func handle(letter: String) -> Bool {
        switch letter {
        case "k": activate()
        case "j": seek(by: -5)
        case "l": seek(by: 5)
        case "n": step(1)
        case "p": step(-1)
        case "m": toggleMute()
        case "s": toggleLater()
        case "c", "i": setDetails(shown: detailsShown.target == 0, focusing: true)
        case "o": openChannel()
        case "a": cycleAutoScroll()
        case "[": stepSpeed(-1)
        case "]": stepSpeed(1)
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            guard let slot = currentSlot, let tenth = Double(letter), slot.player.state.duration > 0 else { return true }
            slot.seek(to: slot.player.state.duration * tenth / 10)
        case "f": toggleFullscreen()
        default: return false
        }
        return true
    }

    private func toggleFullscreen() {
        guard let window else { return }
        window.setFullscreen(!window.isFullscreen)
    }

    /// Enter, Space, A on a gamepad and a click: the clip that failed is tried again, any other pauses or plays.
    override func activate() {
        if case .failed = currentSlot?.phase {
            retry()
            return
        }
        togglePause()
    }

    override func showContextMenu(at point: Point?) -> Bool {
        presentMenu(at: point.map { transformToWindow.apply($0) })
        return true
    }

    override func gamepadTriggered(left: Float, right: Float) -> Bool {
        triggerPull = right - left
        guard abs(triggerPull) > 0.15 else {
            triggerScrub?.cancel()
            triggerScrub = nil
            return true
        }
        guard triggerScrub == nil else { return true }
        triggerScrub = Task { [weak self] in
            while !Task.isCancelled, let self, abs(self.triggerPull) > 0.15 {
                self.seek(by: Double(self.triggerPull) * 1.5, quietly: true)
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
        return true
    }

    // MARK: Pointer

    private func barZone(of page: WebShortPage) -> Rect {
        let reach = Theme.current.metrics.tv(22)
        return page.barRect.insetBy(0, -reach)
    }

    override func pointerMoved(to point: Point) {
        guard let page = currentPage, scrub == nil else { return }
        let local = page.convert(point, from: self)
        page.emphasizesBar = barZone(of: page).contains(local) || isPaused
        page.hoveredRegion = press == nil ? page.region(at: local) : nil
        if page.hoveredRegion == .details, let entry = current { requestComments(for: entry) }
    }

    override func pointerExited() {
        if scrub == nil { currentPage?.emphasizesBar = isPaused }
        currentPage?.hoveredRegion = nil
    }

    override func cursor(at point: Point) -> Cursor {
        guard let page = currentPage else { return .default }
        let local = page.convert(point, from: self)
        return barZone(of: page).contains(local) || page.region(at: local) != nil ? .pointer : .default
    }

    override func tooltip(at point: Point) -> String? {
        guard let page = currentPage else { return nil }
        switch page.region(at: page.convert(point, from: self)) {
        case .channel: return "\(WebShortsCopy.goToChannel) (O)"
        case .details: return "\(WebShortsCopy.details) (C)"
        case nil: return nil
        }
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard !closed else { return true }
        if button == .secondary {
            presentMenu(at: transformToWindow.apply(point))
            return true
        }
        guard button == .primary else { return false }
        window?.focus.focus(self, animated: false)
        if let page = currentPage, let slot = currentSlot, slot.phase == .open, slot.player.state.duration > 0,
           barZone(of: page).contains(page.convert(point, from: self)) {
            scrub = (page, !isPaused)
            slot.plays = false
            page.emphasizesBar = true
            scrubbed(to: point, exact: false)
            return true
        }
        press = (point, false, point)
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, !Task.isCancelled, let held = self.press, !held.dragging, self.stage.pane.contains(held.start),
                  self.currentPage.map({ $0.region(at: $0.convert(held.start, from: self)) == nil }) ?? false else { return }
            self.setFast(true)
        }
        return true
    }

    /// Plays the clip at twice its speed while the pointer is held on it, as phones do, and back at its own speed on letting go.
    private func setFast(_ fast: Bool) {
        guard fast != isFast else { return }
        isFast = fast
        currentSlot?.player.setLater("speed", String(fast ? min(WebSettings.shortsSpeed * 2, 4) : WebSettings.shortsSpeed))
        if fast { toast.show(WebShortsCopy.doubleSpeed, symbol: "forward.fill") }
    }

    override func pointerDragged(to point: Point) {
        if scrub != nil {
            scrubbed(to: point, exact: false)
            return
        }
        guard var held = press else { return }
        if !held.dragging, !isFast, abs(point.y - held.start.y) > Theme.current.metrics.tv(14) {
            holdTask?.cancel()
            held.dragging = true
            held.last = held.start
            preparePager()
        }
        if held.dragging {
            let pulled = pager.drag(by: (held.last.y - point.y) / stage.pitch, at: Window.now())
            held.last = point
            offset.reset(Float(index) + pulled)
            setNeedsLayout()
        }
        press = held
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        if let scrub {
            scrubbed(to: point, exact: true)
            scrub.page.scrubbing = nil
            scrub.page.emphasizesBar = isPaused
            currentSlot?.plays = scrub.resumes
            self.scrub = nil
            return
        }
        guard let held = press else { return }
        press = nil
        holdTask?.cancel()
        if isFast {
            setFast(false)
            return
        }
        if held.dragging {
            let moved = pager.release(at: Window.now())
            if moved == 0 { settle() } else { show(index + moved) }
            return
        }
        clicked(at: point)
    }

    /// A click on the clip pauses or plays and a second one fills the screen instead, putting the pause back; a click
    /// above or below the clip moves through the feed, and one beside it puts the details sheet away.
    private func clicked(at point: Point) {
        let pane = stage.pane
        if pane.contains(point), let page = currentPage, let region = page.region(at: page.convert(point, from: self)) {
            switch region {
            case .channel: openChannel()
            case .details: setDetails(shown: detailsShown.target == 0, focusing: false)
            }
        } else if pane.contains(point) {
            if window?.clickCount == 2 {
                if lastClickToggled { togglePause(quietly: true) }
                lastClickToggled = false
                toggleFullscreen()
            } else {
                lastClickToggled = true
                activate()
            }
        } else if point.x >= pane.minX, point.x <= pane.maxX {
            step(point.y < pane.minY ? -1 : 1)
        } else if detailsShown.target == 1 {
            setDetails(shown: false)
        }
    }

    private func scrubbed(to point: Point, exact: Bool) {
        guard let scrub, let slot = currentSlot else { return }
        let bar = scrub.page.barRect
        let local = scrub.page.convert(point, from: self)
        let fraction = Double(min(max((local.x - bar.minX) / max(bar.width, 1), 0), 1))
        scrub.page.scrubbing = fraction
        slot.seek(to: fraction * slot.player.state.duration, exact: exact)
    }

    private func preparePager() {
        pager.canGoBack = index > 0
        pager.canGoOn = index < entries.count - 1
    }

    override func scrolled(_ event: ScrollEvent) -> Bool {
        guard !closed, scrub == nil, press == nil else { return true }
        preparePager()
        let now = Window.now()
        if event.isDiscrete {
            let moved = pager.wheel(event.notchesY, at: now)
            if moved != 0 { show(index + moved) }
            return true
        }
        if event.dy != 0 {
            offset.reset(Float(index) + pager.drag(by: event.dy / stage.pitch, at: now))
            setNeedsLayout()
        }
        if event.ended {
            let moved = pager.release(at: now)
            if moved == 0 { settle() } else { show(index + moved) }
        }
        return true
    }

    // MARK: Closing

    /// Stops the clips and fades the player away.
    func close(animated: Bool = true) {
        guard !closed else { return }
        noteWatched()
        closed = true
        tearDown()
        guard animated, window != nil, !Animation.reduceMotion else {
            finishClosing()
            return
        }
        appearance.set(0, animation: .timed(duration: 0.18, curve: .easeIn))
        startAnimating()
    }

    private func tearDown() {
        landing?.cancel()
        commentsTask?.cancel()
        channelTask?.cancel()
        washTask?.cancel()
        triggerScrub?.cancel()
        for page in pages.values { page.slot = nil }
        for slot in slots { slot.shutDown() }
        slots = []
        if window != nil { ScreenAwake.hold(false, in: window) }
    }

    private func finishClosing() {
        let done = onClose
        onClose = nil
        done?()
    }
}
