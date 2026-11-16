import Foundation

/// What a window asks of the app: commands the focused views did not take, and closing.
@MainActor
public protocol WindowDelegate: AnyObject {
    /// A key no view handled (shortcuts, Escape for back); return whether it was used.
    func window(_ window: Window, unhandledKey event: KeyEvent) -> Bool
    /// A mouse button no view handled (the back and forward buttons walk history).
    func window(_ window: Window, unhandledButton button: MouseButton) -> Bool
    /// The window gained or lost the keyboard: the app came back to it, or went elsewhere.
    func window(_ window: Window, keyboardFocusChanged focused: Bool)
    /// The wheel or touchpad scrolled with Ctrl held (zoom, as in a browser): return whether it was used, or the scroll
    /// goes to the views under the pointer.
    func window(_ window: Window, zoomScrolled event: ScrollEvent) -> Bool
    /// A view asked for `link` in a new window of the app (a middle click on a title).
    func window(_ window: Window, openInNewWindow link: URL)
    func windowShouldClose(_ window: Window)
}

extension WindowDelegate {
    public func window(_ window: Window, unhandledKey event: KeyEvent) -> Bool { false }
    public func window(_ window: Window, unhandledButton button: MouseButton) -> Bool { false }
    public func window(_ window: Window, keyboardFocusChanged focused: Bool) {}
    public func window(_ window: Window, zoomScrolled event: ScrollEvent) -> Bool { false }
    public func window(_ window: Window, openInNewWindow link: URL) {}
    public func windowShouldClose(_ window: Window) {}
}

/// A Kiln window: a view tree drawn by libplacebo into an FP16 scRGB swapchain on Wayland (X11 in Steam's Game Mode), or
/// offscreen for tests and the gallery. It owns layout, animation, focus and input routing for its tree.
@MainActor
public final class Window {
    public weak var delegate: WindowDelegate?
    public let gpu: GPU
    let renderer: SceneRenderer
    private let surface: PlatformWindow?
    public let focus = FocusEngine()
    /// The loop the window's Wayland connection runs on (nil offscreen); players and timers attach to it.
    public private(set) weak var loop: EventLoop?
    public private(set) var images: ImageStore?

    /// The root of the tree, filling the window.
    public var contentView: View {
        didSet {
            oldValue.window = nil
            attach(contentView)
        }
    }

    public var background = Color(hex: 0x181818) { didSet { setNeedsDisplay() } }

    /// Size in points.
    public private(set) var size: Size
    /// Device pixels per point (fractional scaling included).
    public private(set) var scale: Float

    public private(set) var isFullscreen = false
    /// Whether the window asked to leave full screen and the compositor has not let it yet, or will not (a rule that keeps
    /// the window full screen).
    public private(set) var isLeavingFullscreen = false
    public private(set) var hasKeyboardFocus = true

    private var needsDisplay = true
    private var changedSinceFrame = true
    private var rendering = false
    private var waitingForFrame = false
    private var lastPresent: Double = 0
    private var refreshInterval: Double = 1.0 / 60
    private var retryAfter: Double = 0
    private var wakeArmed: Double?
    private var animating: [ObjectIdentifier: View] = [:]
    private var parked: [ObjectIdentifier: ParkedView] = [:]
    private var lastShaderSave = Window.now()
    private var lastFrameTime: Double?
    private var hovered: View?
    private var pressed: (view: View, button: MouseButton)?
    private var pointer: Point?
    private var shownCursor: Cursor?
    private var lastClick: (time: Double, point: Point, button: MouseButton)?
    /// How many presses of the same button, close in time and place, the latest one ends: 2 for a double click.
    public private(set) var clickCount = 1
    /// The view holding the window's one text selection.
    public private(set) weak var selectionOwner: (any TextSelecting)?
    public private(set) var modifiers: Modifiers = []
    private var repeatRate: Int32 = 25
    private var repeatDelay: Int32 = 600
    private var repeatTask: Task<Void, Never>?
    private var closed = false
    private let listener: SurfaceListener

    /// Where frame time goes; `KILN_TRACE=path` writes it out, and the HUD draws it.
    public let trace = FrameTrace()

    /// Draws the frame trace's last second over the window (Ctrl+Shift+P in the app) and writes the trace to `hudTraceFile`
    /// while it shows, so a slow moment on a real screen can be read afterwards.
    public var showsPerformanceHUD = false {
        didSet {
            trace.record(to: showsPerformanceHUD ? hudTraceFile : nil)
            setNeedsDisplay()
        }
    }
    /// Where the trace goes while the HUD shows; nil keeps it on screen only.
    public var hudTraceFile: URL?
    /// Builds the label a tooltip shows; without it there are no tooltips.
    public var makeTooltip: ((String) -> View)?
    private var tooltip: (text: String, view: View?)?
    private var tooltipTask: Task<Void, Never>?
    /// How long the pointer rests before a tooltip shows.
    private static let tooltipDelay: Duration = .milliseconds(650)

    /// Frames drawn (and presented, on Wayland) since the window opened.
    public private(set) var frameCount = 0

    // MARK: Creation

    /// An offscreen window of `size` points at `scale`: rendering, layout, focus and input without a display, on its own
    /// GPU device or a shared one.
    public init(offscreen size: Size, scale: Float = 1, gpu shared: GPU? = nil, contentView: View = View()) throws(RenderError) {
        if let shared {
            gpu = shared
        } else {
            gpu = try GPU(display: nil, surface: nil)
        }
        surface = nil
        listener = SurfaceListener()
        self.size = size
        self.scale = scale
        surfaceSize = size
        outputScale = scale
        renderer = try SceneRenderer(gpu: gpu, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
        renderer.scale = scale
        self.contentView = contentView
        focus.window = self
        attach(contentView)
    }

    /// Opens a toplevel on the session's display (`PlatformWindow.makeForSession`) and its swapchain, then the loop drives
    /// it. Compiled shaders persist in `shaderCache`, so a launch after the first draws its first frames without compiling.
    public init(title: String, appID: String, loop: EventLoop, contentView: View = View(), shaderCache: URL? = nil) throws(RenderError) {
        guard let surface = PlatformWindow.makeForSession() else { throw .device("no Wayland or X11 display") }
        let listener = SurfaceListener()
        guard surface.open(title: title, appID: appID, delegate: listener) else { throw .device("window") }
        self.surface = surface
        self.listener = listener
        self.loop = loop
        _ = surface.pump(readable: false)
        size = Size(width: Float(surface.width), height: Float(surface.height))
        scale = Float(surface.scale)
        surfaceSize = size
        outputScale = scale
        gpu = try surface.makeGPU()
        if let shaderCache { gpu.useShaderCache(at: shaderCache) }
        renderer = try SceneRenderer(gpu: gpu, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
        renderer.scale = scale
        renderer.prewarm()
        self.contentView = contentView
        listener.window = self
        if let refresh = surface.refreshNanoseconds { refreshInterval = Double(refresh) / 1e9 }
        focus.window = self
        attach(contentView)
        accessibility = AccessibilityBridge(window: self, title: title)
        accessibility?.onActiveChange = { [weak self] _ in self?.setNeedsDisplay() }
        fitSwapchain(width: renderer.viewport.width, height: renderer.viewport.height)
        loop.add(fd: surface.fileDescriptor) { [weak self] readable in
            guard let self, let surface = self.surface, !self.closed else { return }
            if !surface.pump(readable: readable) {
                self.delegate?.windowShouldClose(self)
                return
            }
            self.checkDisplayColor()
        }
        checkDisplayColor()
        if let secondary = surface.secondaryFileDescriptor {
            loop.add(fd: secondary) { [weak self] readable in
                guard readable, let self, let surface = self.surface, !self.closed else { return }
                _ = surface.pump(readable: false)
                self.checkDisplayColor()
            }
        }
        loop.atEndOfEachTurn { [weak self] in self?.renderIfDue() }
        setNeedsDisplay()
    }

    /// What the compositor says about the screen the window is on (`DisplayColor`), read again whenever it announces a
    /// change: the window moved to another screen, HDR went on or off, the brightness or the desktop's calibration changed.
    public private(set) var displayColor: DisplayColor?
    /// Called when `displayColor` changed.
    public var onDisplayColorChange: ((DisplayColor?) -> Void)?
    private var displayColorSerial: UInt32 = .max

    /// Reads the description again when the compositor announced a change, and again should another arrive during the
    /// read's own roundtrips.
    private func checkDisplayColor() {
        guard let surface else { return }
        var color = displayColor
        for _ in 0..<3 {
            let serial = surface.displayColorSerial
            guard serial != displayColorSerial else { break }
            displayColorSerial = serial
            color = surface.readDisplayColor()
        }
        guard color != displayColor else { return }
        displayColor = color
        gpu.setOutput(gain: surface.outputGain, sdr: surface.prefersSDROutput)
        setNeedsDisplay()
        onDisplayColorChange?(color)
    }

    /// Attaches an image store that views load artwork through.
    public func useImages(diskDirectory: URL?, fetch: @escaping ImageStore.Fetch) {
        images = ImageStore(gpu: gpu, diskDirectory: diskDirectory, fetch: fetch)
    }

    private func attach(_ view: View) {
        view.frame = Rect(origin: .zero, size: size)
        view.window = self
        view.setNeedsLayout()
        setNeedsDisplay()
    }

    /// Closes the window; the app's loop stops watching its display and screen readers stop seeing it, so a closed window
    /// costs nothing while others stay.
    public func close() {
        guard !closed else { return }
        closed = true
        trace.flushFrames()
        accessibility = nil
        if let surface {
            loop?.remove(fd: surface.fileDescriptor)
            if let secondary = surface.secondaryFileDescriptor { loop?.remove(fd: secondary) }
        }
        repeatTask?.cancel()
        contentView.window = nil
        gpu.finish()
        gpu.saveShaderCache()
        gpu.releaseSurface()
        surface?.close()
    }

    public func setFullscreen(_ fullscreen: Bool) {
        isLeavingFullscreen = !fullscreen && isFullscreen
        surface?.setFullscreen(fullscreen)
    }

    public func setCursor(_ cursor: Cursor) {
        shownCursor = cursor
        surface?.setCursor(cursor)
    }

    /// Keeps the screen awake over the window; false when the compositor cannot (gamescope), for a fallback to take over.
    @discardableResult
    public func inhibitIdle(_ inhibit: Bool) -> Bool {
        surface?.inhibitIdle(inhibit) ?? false
    }

    /// Drops the decoded artwork nothing on screen holds, for when memory runs short.
    public func purgeImageMemory() {
        images?.purgeMemory()
    }

    /// Brings the window to the front with an xdg-activation token a launcher handed a later launch of the app.
    @discardableResult
    public func activate(token: String) -> Bool {
        surface?.activate(token: token) ?? false
    }

    /// The link to screen readers; offscreen windows have none.
    private var accessibility: AccessibilityBridge?

    /// Whether a screen reader such as Orca is listening, when read-only panels become focus stops so it reaches them.
    public var isScreenReaderActive: Bool { simulatesScreenReader || (accessibility?.isActive ?? false) }

    /// Behaves as if a screen reader listened, for tests and the gallery.
    public var simulatesScreenReader = false

    /// The focus moved: the input method and the screen reader follow it.
    func focusDidMove() {
        textInputFocusChanged()
        accessibility?.focusChanged()
    }

    /// The focused view when it takes text from the input method.
    public private(set) weak var textInputClient: (any TextInputClient)?

    /// The focus moved: the input method turns on for a text field that took it, with that field's state, and off when
    /// focus left text fields.
    func textInputFocusChanged() {
        let client = focus.focusedView as? any TextInputClient
        guard client !== textInputClient else { return }
        textInputClient = client
        if let client, let view = client as? View { sendTextInputState(client.textInputState, of: view) }
        surface?.setTextInputEnabled(client != nil)
    }

    /// A text field's text or caret changed: the input method hears the new state when the field has the focus.
    public func textInputChanged(_ client: any TextInputClient) {
        guard client === textInputClient, let view = client as? View else { return }
        sendTextInputState(client.textInputState, of: view)
    }

    private func sendTextInputState(_ state: TextInputState, of view: View) {
        let caret = view.transformToWindow.apply(state.caret)
        surface?.updateTextInput(state, caret: Rect(x: caret.minX * canvasZoom, y: caret.minY * canvasZoom, width: caret.width * canvasZoom,
                                                    height: caret.height * canvasZoom))
    }

    /// A gamepad's right stick: the focused view and its ancestors in turn (the content view when nothing has the focus),
    /// until one takes it.
    public func gamepadTilt(x: Float, y: Float) {
        var responder: View? = focus.focusedView ?? contentView
        while let view = responder {
            if view.gamepadTilted(x: x, y: y) { return }
            responder = view.superview
        }
    }

    /// A gamepad's triggers: the focused view and its ancestors in turn (the content view when nothing has the focus),
    /// until one takes them.
    public func gamepadTriggers(left: Float, right: Float) {
        var responder: View? = focus.focusedView ?? contentView
        while let view = responder {
            if view.gamepadTriggered(left: left, right: right) { return }
            responder = view.superview
        }
    }

    /// The name of the screen the window is on ("DP-3"), which KWin's output management knows it by; nil offscreen.
    public var outputName: String? { surface?.outputName }
    /// The compositor's description of the screen the window is on (make, model, connector).
    public var outputDescription: String? { surface?.outputDescription }

    /// The diagonal of the screen the window is on, in inches, from the size the screen reports; nil offscreen or when the
    /// screen reports none.
    public var screenDiagonalInches: Float? {
        guard let size = surface?.screenSizeMillimetres else { return nil }
        let width = Float(size.width)
        let height = Float(size.height)
        return (width * width + height * height).squareRoot() / 25.4
    }

    /// Hands `link` to the app to open in a new window.
    public func openInNewWindow(_ link: URL) {
        delegate?.window(self, openInNewWindow: link)
    }

    /// Makes `owner`'s selection the window's, clearing the one another view held.
    public func claimSelection(_ owner: any TextSelecting) {
        if let previous = selectionOwner, previous !== owner { previous.clearSelection() }
        selectionOwner = owner
    }

    /// Puts `text` on the desktop's clipboard (Ctrl+C, a menu's Copy). Headless windows keep it to themselves.
    public func copy(_ text: String) {
        localClipboard = text
        copiedData = nil
        surface?.setClipboard(text)
    }

    /// Puts `data` of type `mimeType` (a PNG as "image/png") on the desktop's clipboard. Headless windows keep it in
    /// `copiedData`.
    public func copy(_ data: Data, mimeType: String) {
        localClipboard = nil
        copiedData = (mimeType, data)
        surface?.setClipboard(data, mimeType: mimeType)
    }

    /// What `copy(_:mimeType:)` last put on the clipboard, until text replaces it.
    public private(set) var copiedData: (mimeType: String, data: Data)?

    /// The desktop clipboard's text (Ctrl+V), or what this window copied when it has no desktop.
    public func pasteboardText() -> String? {
        guard let surface else { return localClipboard }
        return surface.clipboardText()
    }

    private var localClipboard: String?

    /// Brings the window forward on a request that came with no token (the desktop's media controls).
    @discardableResult
    public func raise() -> Bool {
        surface?.raise() ?? false
    }

    // MARK: Drawing

    /// Asks for a frame; it is drawn at the end of the event-loop turn, after every pending input has been handled.
    public func setNeedsDisplay() {
        needsDisplay = true
        if !rendering { changedSinceFrame = true }
    }

    /// Draws a frame at the end of an event-loop turn once one is due. A change (input, loaded artwork, a video frame)
    /// draws straight away, or within a refresh when the compositor has not yet shown the last frame, so input never
    /// waits on a late compositor; animation ticks wait for the compositor's frame callback, so an occluded window
    /// stops drawing. Mailbox presentation keeps either from blocking.
    private func renderIfDue() {
        guard needsDisplay, surface != nil, !closed else { return }
        if waitingForFrame && !changedSinceFrame { return }
        let now = Window.now()
        let earliest = max(lastPresent + refreshInterval * (waitingForFrame ? 1 : 0.75), retryAfter)
        if now < earliest {
            wake(at: earliest)
            return
        }
        renderIfNeeded(time: now)
    }

    /// Wakes the event loop at `time` so the turn's end can draw the frame that was not yet due.
    private func wake(at time: Double) {
        if let wakeArmed, wakeArmed <= time { return }
        wakeArmed = time
        DispatchQueue.main.asyncAfter(deadline: .now() + max(time - Window.now(), 0)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wakeArmed == time else { return }
                self.wakeArmed = nil
            }
        }
    }

    /// Registers a view whose animated values move; it is advanced every frame until it reports it has settled. A view
    /// that animates every frame, starting while only ambient views ran, starts from a fresh clock, so its first step is
    /// not the time since the last ambient frame.
    func startAnimating(_ view: View) {
        if view.animationInterval == nil && !animating.values.contains(where: { $0.animationInterval == nil }) { lastFrameTime = nil }
        animating[ObjectIdentifier(view)] = view
        setNeedsDisplay()
    }

    public var isAnimating: Bool { !animating.isEmpty }

    /// Lays out, advances animations to `time` (seconds, monotonic) and draws, if anything changed.
    func renderIfNeeded(time: Double = Window.now()) {
        guard needsDisplay, !closed else { return }
        needsDisplay = false
        changedSinceFrame = false
        rendering = true
        defer { rendering = false }
        var frame = trace.begin()
        frame.animatingViews = animating.count
        if trace.isWriting { frame.animatingNames = animating.values.map { String(describing: type(of: $0)) } }
        let dt = Float(min(max(time - (lastFrameTime ?? time), 0), 0.1))
        lastFrameTime = animating.isEmpty ? nil : time
        var mark = Window.now()
        advanceAnimations(dt, at: time)
        if !animating.isEmpty { lastFrameTime = time }
        frame.animate = Window.now() - mark
        mark = Window.now()
        contentView.layoutIfNeeded()
        frame.layout = Window.now() - mark
        mark = Window.now()
        renderer.render(root: contentView, background: background)
        if showsPerformanceHUD { renderer.drawHUD(trace.summary) }
        frame.draw = Window.now() - mark
        frameCount += 1
        if let surface {
            mark = Window.now()
            surface.requestFrame()
            trace.frameRequested()
            if gpu.present(renderer.target, width: renderer.viewport.width, height: renderer.viewport.height) {
                waitingForFrame = true
                lastPresent = mark
            } else {
                presentFailed(at: mark)
            }
            surface.flush()
            frame.present = Window.now() - mark
            trace.gpu(gpu.takeGPUMilliseconds())
        }
        let settled = animating.isEmpty && !showsPerformanceHUD
        trace.end(frame, settled: settled)
        accessibility?.frameDrawn()
        if settled {
            saveShadersIfDue(time)
        } else if let due = ambientFrameDue() {
            needsDisplay = false
            scheduleAmbientFrame(at: due)
        } else {
            needsDisplay = true
        }
    }

    /// When the next frame is due if every animating view is ambient (has an `animationInterval`); nil when one wants every
    /// frame. The views' own requests to draw while they stepped are what the schedule replaces. While the window lacks the
    /// keyboard (Steam's overlay or screensaver is over it, or another window is in front) ambient views step once a second.
    private func ambientFrameDue() -> Double? {
        guard !showsPerformanceHUD else { return nil }
        var due = Double.infinity
        for (key, view) in animating {
            guard let interval = view.animationInterval else { return nil }
            due = min(due, (ambientSteps[key] ?? 0) + (hasKeyboardFocus ? interval : max(interval, 1)))
        }
        return due.isFinite ? due : nil
    }

    private var ambientSteps: [ObjectIdentifier: Double] = [:]
    private var ambientWake: Double?

    /// Draws again at `time` for the ambient views, unless something draws sooner.
    private func scheduleAmbientFrame(at time: Double) {
        if let ambientWake, ambientWake <= time, ambientWake > Window.now() { return }
        ambientWake = time
        DispatchQueue.main.asyncAfter(deadline: .now() + max(time - Window.now(), 0)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ambientWake == time else { return }
                self.ambientWake = nil
                self.setNeedsDisplay()
            }
        }
    }

    /// Advances every animating view; a view that settled, left the window, or sits under a hidden ancestor stops (it
    /// starts again when something changes it), so nothing invisible keeps the window drawing. An ambient view is handed
    /// the time since its own last step, up to a quarter second.
    private func advanceAnimations(_ dt: Float, at time: Double) {
        guard !animating.isEmpty else {
            ambientSteps.removeAll()
            return
        }
        for (key, view) in animating {
            var step = dt
            if let interval = view.animationInterval {
                step = Float(min(max(time - (ambientSteps[key] ?? time - interval), 0), 0.25))
                ambientSteps[key] = time
            }
            if view.window !== self {
                animating[key] = nil
            } else if view.isUnderHiddenView {
                animating[key] = nil
                parked[key] = ParkedView(view: view)
            } else if !view.advanceAnimations(step) {
                animating[key] = nil
            }
            if animating[key] == nil { ambientSteps[key] = nil }
        }
    }

    /// Nothing reached the compositor (the swapchain is being rebuilt, or the window is mid-resize), so no frame callback
    /// will come: the frame is drawn again a little later instead of the window waiting forever.
    private func presentFailed(at time: Double) {
        waitingForFrame = false
        retryAfter = time + 0.05
        changedSinceFrame = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.setNeedsDisplay() }
        }
    }

    /// Writes newly compiled shaders to the cache once the window settles, at most every few seconds (a no-op when nothing
    /// new compiled), so a crash still leaves a warm cache behind.
    private func saveShadersIfDue(_ time: Double) {
        guard time - lastShaderSave > 5 else { return }
        lastShaderSave = time
        gpu.saveShaderCache()
    }

    /// A view was shown again: the animations parked under it pick up where they stopped.
    func viewBecameAvailable(_ view: View) {
        guard !parked.isEmpty else { return }
        for (key, entry) in parked {
            guard let parkedView = entry.view, parkedView.window === self else {
                parked[key] = nil
                continue
            }
            guard parkedView === view || parkedView.isDescendant(of: view), !parkedView.isUnderHiddenView else { continue }
            parked[key] = nil
            startAnimating(parkedView)
        }
    }

    /// Monotonic seconds, the clock frames and animations run on.
    public static func now() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_MONOTONIC, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }

    // MARK: Offscreen driving

    /// Draws now (offscreen windows render only when asked).
    public func render() {
        needsDisplay = true
        renderIfNeeded(time: lastFrameTime ?? 0)
    }

    /// Advances animations by `seconds` in 1/120 s steps and draws, for deterministic tests and gallery captures.
    public func advance(by seconds: Double) {
        var time = lastFrameTime ?? 0
        let end = time + seconds
        lastFrameTime = time
        while time < end - 1e-9 {
            time = min(time + 1.0 / 120, end)
            needsDisplay = true
            renderIfNeeded(time: time)
        }
    }

    /// Settles every animation and draws the result.
    public func settle() {
        var steps = 0
        while isAnimating && steps < 2400 {
            advance(by: 1.0 / 120)
            steps += 1
        }
        render()
    }

    /// The last drawn frame as linear RGBA floats, top row first.
    public func capture() -> (width: Int, height: Int, pixels: [Float]) {
        gpu.finish()
        let full = renderer.target.download()
        let (width, height) = renderer.viewport
        guard width != renderer.target.width || height != renderer.target.height else { return (width, height, full) }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let from = row * renderer.target.width * 4
            pixels.replaceSubrange(row * width * 4..<(row + 1) * width * 4, with: full[from..<from + width * 4])
        }
        return (width, height, pixels)
    }

    // MARK: Resizing

    /// The window's size in the compositor's points and the output's scale, before any canvas.
    private var surfaceSize = Size.zero
    private var outputScale: Float = 1

    /// When set, the content is laid out at this size in points and drawn scaled to fit the window, wider or taller where
    /// the window's shape differs (Couch's 1920 by 1080 tvOS canvas on any screen).
    public var canvas: Size? {
        didSet {
            guard canvas != oldValue, surfaceSize.width > 0 else { return }
            resize(width: Int(surfaceSize.width), height: Int(surfaceSize.height), scale: outputScale)
        }
    }

    /// How much larger than the compositor's points the content is drawn: the canvas fitted to the window, or 1.
    public private(set) var canvasZoom: Float = 1

    func resize(width: Int, height: Int, scale newScale: Float) {
        surfaceSize = Size(width: Float(width), height: Float(height))
        outputScale = newScale
        let zoom = canvas.map { min(Float(width) / max($0.width, 1), Float(height) / max($0.height, 1)) }.flatMap { $0 > 0 ? $0 : nil } ?? 1
        canvasZoom = zoom
        size = Size(width: Float(width) / zoom, height: Float(height) / zoom)
        scale = newScale * zoom
        renderer.scale = scale
        let pixelWidth = Int((Float(width) * newScale).rounded())
        let pixelHeight = Int((Float(height) * newScale).rounded())
        if let surface {
            surface.applyScale(logicalWidth: width, logicalHeight: height)
            fitSwapchain(width: pixelWidth, height: pixelHeight)
        }
        try? renderer.resize(width: pixelWidth, height: pixelHeight)
        contentView.frame = Rect(origin: .zero, size: size)
        invalidateLayout(contentView)
        setNeedsDisplay()
    }

    /// The swapchain's size, a step larger than the window where the compositor crops buffers (`cropBuffer`).
    private var swapchainSize: (width: Int, height: Int)?

    /// Sizes the swapchain for a window of `width` by `height` pixels. Where the compositor crops the window's buffers, the
    /// swapchain is a step larger and only recreated when the window outgrows it or shrinks well inside it, as the render
    /// target is: recreating it for every size a dragged edge passes through allocates new buffers, waits for the GPU and
    /// makes the compositor import them each time.
    private func fitSwapchain(width: Int, height: Int) {
        guard let surface else { return }
        guard surface.canCropBuffer else {
            _ = gpu.resize(width: width, height: height)
            return
        }
        let fits = swapchainSize.map { width <= $0.width && height <= $0.height } ?? false
        let roomy = swapchainSize.map { width * 4 >= $0.width * 3 || height * 4 >= $0.height * 3 } ?? false
        if !fits || !roomy, let made = gpu.resize(width: SceneRenderer.allocated(width + 128), height: SceneRenderer.allocated(height + 128)) {
            swapchainSize = made
        }
        guard let size = swapchainSize else { return }
        surface.cropBuffer(width: min(width, size.width), height: min(height, size.height))
    }

    private func invalidateLayout(_ view: View) {
        view.setNeedsLayout()
        for subview in view.subviews { invalidateLayout(subview) }
    }

    /// Resizes an offscreen window.
    public func resizeOffscreen(to size: Size, scale: Float? = nil) {
        resize(width: Int(size.width), height: Int(size.height), scale: scale ?? outputScale)
    }

    // MARK: Focus

    public var focusedView: View? { focus.focusedView }

    /// Whether the keyboard (or a gamepad) has been used since the last click, so focus is drawn.
    public var isFocusVisible: Bool { focus.isVisible }

    func viewBecameUnavailable(_ view: View, formerSuperview: View?, handingOn: Bool = false) {
        if let hovered, hovered.isDescendant(of: view) {
            self.hovered = nil
            hovered.isHovered = false
            hovered.pointerExited()
        }
        focus.viewBecameUnavailable(view, formerSuperview: formerSuperview, handingOn: handingOn)
    }

    // MARK: Input

    /// A key from the keymap: the focused view and its ancestors first, then focus movement, then the delegate.
    public func handleKey(_ event: KeyEvent) {
        trace.inputArrived()
        hideTooltip()
        var responder = focus.focusedView
        while let view = responder {
            if view.keyPressed(event) { return }
            responder = view.superview
        }
        if event.clipboardCommand == .copy, let text = selectionOwner?.selectedText {
            copy(text)
            return
        }
        if contentView.keyPressed(event) { return }
        if focus.handle(event) { return }
        _ = delegate?.window(self, unhandledKey: event)
    }

    public func handlePointerMoved(to point: Point) {
        pointer = point
        let hit = contentView.hitTest(point)
        if hit !== hovered {
            hovered?.isHovered = false
            hovered?.pointerExited()
            hovered = hit
            hit?.isHovered = true
            hit?.pointerEntered()
        }
        if let hit { hit.pointerMoved(to: hit.convert(point, from: nil)) }
        if let pressed { pressed.view.pointerDragged(to: pressed.view.convert(point, from: nil)) }
        showCursor((pressed?.view ?? hit).map { $0.cursor(at: $0.convert(point, from: nil)) } ?? .default)
        updateTooltip(hit.flatMap { $0.tooltip(at: $0.convert(point, from: nil)) })
    }

    /// Shows `text` near the pointer once it has rested there, or takes the tooltip away when the pointer left what had one.
    private func updateTooltip(_ text: String?) {
        guard text != tooltip?.text else { return }
        hideTooltip()
        guard let text, makeTooltip != nil else { return }
        tooltip = (text, nil)
        tooltipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Window.tooltipDelay)
            guard !Task.isCancelled, let self, self.tooltip?.text == text, let pointer = self.pointer, let view = self.makeTooltip?(text) else { return }
            let size = view.sizeThatFits(self.contentView.bounds.size)
            let bounds = self.contentView.bounds
            let below = pointer.y + 26
            let y = below + size.height > bounds.height - 8 ? pointer.y - 12 - size.height : below
            let x = min(max(pointer.x - size.width / 2, 8), bounds.width - size.width - 8)
            view.frame = Rect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
            self.contentView.addSubview(view)
            self.tooltip = (text, view)
        }
    }

    private func hideTooltip() {
        tooltipTask?.cancel()
        tooltipTask = nil
        tooltip?.view?.removeFromSuperview()
        tooltip = nil
    }

    /// Sets the pointer's shape when it changed; the compositor forgets it when the pointer leaves.
    private func showCursor(_ cursor: Cursor) {
        guard cursor != shownCursor else { return }
        shownCursor = cursor
        surface?.setCursor(cursor)
    }

    /// Counts `button` presses in a row: each within 0.45 seconds and a few points of the one before.
    private func countClick(_ button: MouseButton, at point: Point) {
        let now = Window.now()
        if let last = lastClick, last.button == button, now - last.time < 0.45, abs(last.point.x - point.x) < 5, abs(last.point.y - point.y) < 5 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClick = (now, point, button)
    }

    /// Where the pointer is over the window, in window points; nil once it has left.
    public var pointerLocation: Point? { pointer }

    public func handlePointerLeft() {
        hideTooltip()
        shownCursor = nil
        pointer = nil
        hovered?.isHovered = false
        hovered?.pointerExited()
        hovered = nil
    }

    public func handlePointerButton(_ button: MouseButton, pressed isPressed: Bool) {
        trace.inputArrived()
        guard let pointer else { return }
        if isPressed {
            hideTooltip()
            focus.pointerDidClick()
            countClick(button, at: pointer)
            var responder = contentView.hitTest(pointer)
            while let view = responder {
                if view.pointerPressed(button, at: view.convert(pointer, from: nil)) {
                    if self.pressed == nil || self.pressed?.button == button { self.pressed = (view, button) }
                    if let owner = selectionOwner, owner !== view { owner.clearSelection() }
                    return
                }
                responder = view.superview
            }
            selectionOwner?.clearSelection()
            if delegate?.window(self, unhandledButton: button) == true { return }
        } else if let pressed, pressed.button == button {
            self.pressed = nil
            let local = pressed.view.convert(pointer, from: nil)
            pressed.view.pointerReleased(button, at: local, inside: pressed.view.bounds.contains(local) && pressed.view.window === self)
        }
    }

    public func handleScroll(_ event: ScrollEvent) {
        trace.inputArrived()
        var scroll = event
        scroll.modifiers = modifiers.union(event.modifiers)
        if scroll.modifiers.contains(.control), delegate?.window(self, zoomScrolled: scroll) == true { return }
        if scroll.modifiers.contains(.shift), scroll.isDiscrete, scroll.dx == 0 {
            scroll.dx = scroll.dy
            scroll.notchesX = scroll.notchesY
            scroll.dy = 0
            scroll.notchesY = 0
        }
        guard let pointer else { return }
        var responder = contentView.hitTestAny(pointer)
        while let view = responder {
            if view.scrolled(scroll) { return }
            responder = view.superview
        }
    }

    func keyFromSurface(_ event: KeyEvent, pressed isPressed: Bool, repeats: Bool) {
        repeatTask?.cancel()
        repeatTask = nil
        guard isPressed else { return }
        handleKey(event)
        guard repeats, repeatRate > 0 else { return }
        let delay = UInt64(max(repeatDelay, 1)) * 1_000_000
        let interval = UInt64(1_000_000_000 / Int(repeatRate))
        repeatTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            while !Task.isCancelled {
                guard let self else { return }
                self.handleKey(KeyEvent(key: event.key, text: event.text, modifiers: event.modifiers, isRepeat: true))
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    // MARK: Wayland

    /// Receives the toplevel's events on the main actor.
    @MainActor
    final class SurfaceListener: PlatformWindowDelegate {
        weak var window: Window?

        func windowConfigured(_ surface: PlatformWindow, width: Int, height: Int, fullscreen: Bool) {
            guard let window else { return }
            window.isFullscreen = fullscreen
            if !fullscreen { window.isLeavingFullscreen = false }
            window.resize(width: width, height: height, scale: Float(surface.scale))
        }

        func windowClosed(_ surface: PlatformWindow) {
            guard let window else { return }
            window.delegate?.windowShouldClose(window)
        }

        func windowScaleChanged(_ surface: PlatformWindow, scale: Double) {
            guard let window else { return }
            window.resize(width: Int(window.surfaceSize.width), height: Int(window.surfaceSize.height), scale: Float(scale))
        }

        func windowPresented(_ surface: PlatformWindow, nanoseconds: UInt64, refreshNanoseconds: UInt32, sequence: UInt64) {
            guard let window else { return }
            if nanoseconds > 0 { window.trace.presented(at: Double(nanoseconds) / 1e9) }
            guard refreshNanoseconds > 1_000_000 else { return }
            window.refreshInterval = Double(refreshNanoseconds) / 1e9
        }

        func windowFrameDone(_ surface: PlatformWindow) {
            guard let window else { return }
            window.waitingForFrame = false
            window.trace.frameCallbackArrived()
        }

        func windowPointerMoved(_ surface: PlatformWindow, x: Double, y: Double) {
            guard let window else { return }
            window.handlePointerMoved(to: Point(x: Float(x) / window.canvasZoom, y: Float(y) / window.canvasZoom))
        }

        func windowPointerLeft(_ surface: PlatformWindow) {
            window?.handlePointerLeft()
        }

        func windowPointerButton(_ surface: PlatformWindow, button: UInt32, pressed: Bool) {
            window?.handlePointerButton(MouseButton(code: button), pressed: pressed)
        }

        func windowScrolled(_ surface: PlatformWindow, event: ScrollEvent) {
            window?.handleScroll(event)
        }

        func windowKey(_ surface: PlatformWindow, event: KeyEvent, pressed: Bool, repeats: Bool) {
            window?.keyFromSurface(event, pressed: pressed, repeats: repeats)
        }

        func windowModifiersChanged(_ surface: PlatformWindow, modifiers: Modifiers) {
            window?.modifiers = modifiers
        }

        func windowRepeatInfo(_ surface: PlatformWindow, rate: Int32, delay: Int32) {
            window?.repeatRate = rate
            window?.repeatDelay = delay
        }

        func windowTextInput(_ surface: PlatformWindow, event: TextInputEvent) {
            window?.textInputClient?.applyTextInput(event)
        }

        func windowKeyboardFocusChanged(_ surface: PlatformWindow, focused: Bool) {
            guard let window else { return }
            let changed = window.hasKeyboardFocus != focused
            window.hasKeyboardFocus = focused
            window.accessibility?.windowFocusChanged(focused)
            if changed {
                window.delegate?.window(window, keyboardFocusChanged: focused)
                if focused && window.isAnimating { window.setNeedsDisplay() }
            }
            if !focused {
                window.repeatTask?.cancel()
                window.repeatTask = nil
            }
        }
    }
}

/// An animating view under a hidden ancestor, held weakly until it is shown again.
private struct ParkedView {
    weak var view: View?
}

extension View {
    /// Whether this view or an ancestor is hidden (transparency does not count: a view fading in from zero still animates).
    public var isUnderHiddenView: Bool {
        var view: View? = self
        while let current = view {
            if current.isHidden { return true }
            view = current.superview
        }
        return false
    }

    /// The deepest view under `point` whether or not it is interactive: scrolling goes to whatever is under the pointer.
    func hitTestAny(_ point: Point) -> View? {
        guard !isHidden, alpha > 0.01 else { return nil }
        let inside = bounds.contains(point)
        if clipsToBounds && !inside { return nil }
        let inner = Point(x: point.x + contentOffset.x, y: point.y + contentOffset.y)
        for subview in subviews.reversed() {
            if let hit = subview.hitTestAny(subview.transformToSuperview.inverted.apply(inner)) { return hit }
        }
        return inside ? self : nil
    }
}
