import Foundation

/// What a window asks of the app: commands the focused views did not take, and closing.
@MainActor
public protocol WindowDelegate: AnyObject {
    /// A key no view handled (shortcuts, Escape for back); return whether it was used.
    func window(_ window: Window, unhandledKey event: KeyEvent) -> Bool
    /// A mouse button no view handled (the back and forward buttons walk history).
    func window(_ window: Window, unhandledButton button: MouseButton) -> Bool
    func windowShouldClose(_ window: Window)
}

extension WindowDelegate {
    public func window(_ window: Window, unhandledKey event: KeyEvent) -> Bool { false }
    public func window(_ window: Window, unhandledButton button: MouseButton) -> Bool { false }
    public func windowShouldClose(_ window: Window) {}
}

/// A Kiln window: a view tree drawn by libplacebo into an FP16 scRGB swapchain on Wayland, or offscreen for tests and
/// the gallery. It owns layout, animation, focus and input routing for its tree.
@MainActor
public final class Window {
    public weak var delegate: WindowDelegate?
    public let gpu: GPU
    let renderer: SceneRenderer
    private let surface: WaylandWindow?
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
    private var modifiers: Modifiers = []
    private var repeatRate: Int32 = 25
    private var repeatDelay: Int32 = 600
    private var repeatTask: Task<Void, Never>?
    private var closed = false
    private let listener: WaylandListener

    /// Where frame time goes; `KILN_TRACE=path` writes it out, and the HUD draws it.
    public let trace = FrameTrace()

    /// Draws the frame trace's last second over the window (Ctrl+Shift+P in the app).
    public var showsPerformanceHUD = false { didSet { setNeedsDisplay() } }

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
        listener = WaylandListener()
        self.size = size
        self.scale = scale
        renderer = try SceneRenderer(gpu: gpu, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
        renderer.scale = scale
        self.contentView = contentView
        focus.window = self
        attach(contentView)
    }

    /// Opens a toplevel on the Wayland display and its swapchain, then the loop drives it. Compiled shaders persist in
    /// `shaderCache`, so a launch after the first draws its first frames without compiling.
    public init(title: String, appID: String, loop: EventLoop, contentView: View = View(), shaderCache: URL? = nil) throws(RenderError) {
        guard let surface = WaylandWindow() else { throw .device("no Wayland display") }
        let listener = WaylandListener()
        guard surface.open(title: title, appID: appID, delegate: listener) else { throw .device("window") }
        self.surface = surface
        self.listener = listener
        self.loop = loop
        _ = surface.pump(readable: false)
        size = Size(width: Float(surface.width), height: Float(surface.height))
        scale = Float(surface.scale)
        gpu = try GPU(display: surface.display, surface: surface.surface)
        if let shaderCache { gpu.useShaderCache(at: shaderCache) }
        renderer = try SceneRenderer(gpu: gpu, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
        renderer.scale = scale
        self.contentView = contentView
        listener.window = self
        focus.window = self
        attach(contentView)
        _ = gpu.resize(width: renderer.target.width, height: renderer.target.height)
        loop.add(fd: surface.fileDescriptor) { [weak self] readable in
            guard let self, let surface = self.surface, !self.closed else { return }
            if !surface.pump(readable: readable) {
                self.delegate?.windowShouldClose(self)
            }
        }
        loop.atEndOfEachTurn { [weak self] in self?.renderIfDue() }
        setNeedsDisplay()
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

    public func close() {
        guard !closed else { return }
        closed = true
        repeatTask?.cancel()
        contentView.window = nil
        gpu.finish()
        gpu.saveShaderCache()
        gpu.releaseSurface()
        surface?.close()
    }

    public func setFullscreen(_ fullscreen: Bool) {
        surface?.setFullscreen(fullscreen)
    }

    public func setCursor(_ cursor: Cursor) {
        surface?.setCursor(cursor)
    }

    public func inhibitIdle(_ inhibit: Bool) {
        surface?.inhibitIdle(inhibit)
    }

    /// Brings the window to the front with an xdg-activation token a launcher handed a later launch of the app.
    @discardableResult
    public func activate(token: String) -> Bool {
        surface?.activate(token: token) ?? false
    }

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

    /// Registers a view whose animated values move; it is advanced every frame until it reports it has settled.
    func startAnimating(_ view: View) {
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
        advanceAnimations(dt)
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
            if gpu.present(renderer.target) {
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
        if settled {
            saveShadersIfDue(time)
        } else {
            needsDisplay = true
        }
    }

    /// Advances every animating view; a view that settled, left the window, or sits under a hidden ancestor stops (it
    /// starts again when something changes it), so nothing invisible keeps the window drawing.
    private func advanceAnimations(_ dt: Float) {
        guard !animating.isEmpty else { return }
        for (key, view) in animating {
            if view.window !== self {
                animating[key] = nil
            } else if view.isUnderHiddenView {
                animating[key] = nil
                parked[key] = ParkedView(view: view)
            } else if !view.advanceAnimations(dt) {
                animating[key] = nil
            }
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
        return (renderer.target.width, renderer.target.height, renderer.target.download())
    }

    // MARK: Resizing

    func resize(width: Int, height: Int, scale newScale: Float) {
        size = Size(width: Float(width), height: Float(height))
        scale = newScale
        renderer.scale = newScale
        let pixelWidth = Int((Float(width) * newScale).rounded())
        let pixelHeight = Int((Float(height) * newScale).rounded())
        if let surface {
            surface.applyScale(logicalWidth: width, logicalHeight: height)
            _ = gpu.resize(width: pixelWidth, height: pixelHeight)
        }
        try? renderer.resize(width: pixelWidth, height: pixelHeight)
        contentView.frame = Rect(origin: .zero, size: size)
        invalidateLayout(contentView)
        setNeedsDisplay()
    }

    private func invalidateLayout(_ view: View) {
        view.setNeedsLayout()
        for subview in view.subviews { invalidateLayout(subview) }
    }

    /// Resizes an offscreen window.
    public func resizeOffscreen(to size: Size, scale: Float? = nil) {
        resize(width: Int(size.width), height: Int(size.height), scale: scale ?? self.scale)
    }

    // MARK: Focus

    public var focusedView: View? { focus.focusedView }

    /// Whether the keyboard (or a gamepad) has been used since the last click, so focus is drawn.
    public var isFocusVisible: Bool { focus.isVisible }

    func viewBecameUnavailable(_ view: View, formerSuperview: View?) {
        if let hovered, hovered.isDescendant(of: view) {
            self.hovered = nil
            hovered.isHovered = false
            hovered.pointerExited()
        }
        focus.viewBecameUnavailable(view, formerSuperview: formerSuperview)
    }

    // MARK: Input

    /// A key from the keymap: the focused view and its ancestors first, then focus movement, then the delegate.
    public func handleKey(_ event: KeyEvent) {
        trace.inputArrived()
        var responder = focus.focusedView
        while let view = responder {
            if view.keyPressed(event) { return }
            responder = view.superview
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
            surface?.setCursor(hit?.cursor ?? .default)
        }
        if let hit { hit.pointerMoved(to: hit.convert(point, from: nil)) }
    }

    public func handlePointerLeft() {
        pointer = nil
        hovered?.isHovered = false
        hovered?.pointerExited()
        hovered = nil
    }

    public func handlePointerButton(_ button: MouseButton, pressed isPressed: Bool) {
        trace.inputArrived()
        guard let pointer else { return }
        if isPressed {
            focus.pointerDidClick()
            var responder = contentView.hitTest(pointer)
            while let view = responder {
                if view.pointerPressed(button, at: view.convert(pointer, from: nil)) {
                    self.pressed = (view, button)
                    return
                }
                responder = view.superview
            }
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
        scroll.modifiers = modifiers
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
    final class WaylandListener: WaylandWindowDelegate {
        weak var window: Window?

        func windowConfigured(_ surface: WaylandWindow, width: Int, height: Int, fullscreen: Bool) {
            guard let window else { return }
            window.isFullscreen = fullscreen
            window.resize(width: width, height: height, scale: Float(surface.scale))
        }

        func windowClosed(_ surface: WaylandWindow) {
            guard let window else { return }
            window.delegate?.windowShouldClose(window)
        }

        func windowScaleChanged(_ surface: WaylandWindow, scale: Double) {
            guard let window else { return }
            window.resize(width: Int(window.size.width), height: Int(window.size.height), scale: Float(scale))
        }

        func windowPresented(_ surface: WaylandWindow, nanoseconds: UInt64, refreshNanoseconds: UInt32, sequence: UInt64) {
            guard let window, refreshNanoseconds > 1_000_000 else { return }
            window.refreshInterval = Double(refreshNanoseconds) / 1e9
        }

        func windowFrameDone(_ surface: WaylandWindow) {
            guard let window else { return }
            window.waitingForFrame = false
            window.trace.frameCallbackArrived()
        }

        func windowPointerMoved(_ surface: WaylandWindow, x: Double, y: Double) {
            window?.handlePointerMoved(to: Point(x: Float(x), y: Float(y)))
        }

        func windowPointerLeft(_ surface: WaylandWindow) {
            window?.handlePointerLeft()
        }

        func windowPointerButton(_ surface: WaylandWindow, button: UInt32, pressed: Bool) {
            window?.handlePointerButton(MouseButton(code: button), pressed: pressed)
        }

        func windowScrolled(_ surface: WaylandWindow, event: ScrollEvent) {
            window?.handleScroll(event)
        }

        func windowKey(_ surface: WaylandWindow, event: KeyEvent, pressed: Bool, repeats: Bool) {
            window?.keyFromSurface(event, pressed: pressed, repeats: repeats)
        }

        func windowModifiersChanged(_ surface: WaylandWindow, modifiers: Modifiers) {
            window?.modifiers = modifiers
        }

        func windowRepeatInfo(_ surface: WaylandWindow, rate: Int32, delay: Int32) {
            window?.repeatRate = rate
            window?.repeatDelay = delay
        }

        func windowKeyboardFocusChanged(_ surface: WaylandWindow, focused: Bool) {
            guard let window else { return }
            window.hasKeyboardFocus = focused
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
