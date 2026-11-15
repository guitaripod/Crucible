import CKiln

/// What the window reports back to its owner, on the main actor.
@MainActor
public protocol WaylandWindowDelegate: AnyObject {
    func windowConfigured(_ window: WaylandWindow, width: Int, height: Int, fullscreen: Bool)
    func windowClosed(_ window: WaylandWindow)
    func windowScaleChanged(_ window: WaylandWindow, scale: Double)
    func windowPresented(_ window: WaylandWindow, nanoseconds: UInt64, refreshNanoseconds: UInt32, sequence: UInt64)
    func windowFrameDone(_ window: WaylandWindow)
    func windowPointerMoved(_ window: WaylandWindow, x: Double, y: Double)
    func windowPointerLeft(_ window: WaylandWindow)
    func windowPointerButton(_ window: WaylandWindow, button: UInt32, pressed: Bool)
    func windowScrolled(_ window: WaylandWindow, event: ScrollEvent)
    func windowKey(_ window: WaylandWindow, event: KeyEvent, pressed: Bool, repeats: Bool)
    func windowModifiersChanged(_ window: WaylandWindow, modifiers: Modifiers)
    func windowRepeatInfo(_ window: WaylandWindow, rate: Int32, delay: Int32)
    func windowKeyboardFocusChanged(_ window: WaylandWindow, focused: Bool)
}

extension WaylandWindowDelegate {
    public func windowModifiersChanged(_ window: WaylandWindow, modifiers: Modifiers) {}
    public func windowRepeatInfo(_ window: WaylandWindow, rate: Int32, delay: Int32) {}
    public func windowKeyboardFocusChanged(_ window: WaylandWindow, focused: Bool) {}
}

/// One xdg toplevel on its own Wayland connection, with the colour, timing and scale protocols Kiln relies on.
@MainActor
public final class WaylandWindow {
    public struct ColorSupport: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let parametric = ColorSupport(rawValue: UInt32(KILN_COLOR_PARAMETRIC))
        public static let scRGB = ColorSupport(rawValue: UInt32(KILN_COLOR_SCRGB))
        public static let pq = ColorSupport(rawValue: UInt32(KILN_COLOR_PQ))
        public static let bt2020 = ColorSupport(rawValue: UInt32(KILN_COLOR_BT2020))
        public static let mastering = ColorSupport(rawValue: UInt32(KILN_COLOR_MASTERING))
        public static let luminances = ColorSupport(rawValue: UInt32(KILN_COLOR_LUMINANCES))
    }

    public weak var delegate: WaylandWindowDelegate?
    private let connection: OpaquePointer
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var scale = 1.0

    public init?(displayName: String? = nil) {
        guard let connection = kiln_wl_connect(displayName) else { return nil }
        self.connection = connection
    }

    public var fileDescriptor: Int32 { kiln_wl_fd(connection) }
    public var display: OpaquePointer? { kiln_wl_display(connection) }
    public var surface: OpaquePointer? { kiln_wl_surface(connection) }
    public var colorSupport: ColorSupport { ColorSupport(rawValue: kiln_wl_color_features(connection)) }

    public func open(title: String, appID: String, delegate: WaylandWindowDelegate) -> Bool {
        self.delegate = delegate
        let context = Unmanaged.passUnretained(self).toOpaque()
        return kiln_wl_create_window(connection, title, appID, Self.callbacks, context)
    }

    public func pump(readable: Bool) -> Bool {
        kiln_wl_pump(connection, readable) == 0
    }

    public func flush() {
        _ = kiln_wl_flush(connection)
    }

    public func describeAsScRGB() -> Bool {
        kiln_wl_describe_scrgb(connection)
    }

    public func requestFrame() {
        kiln_wl_request_frame(connection)
    }

    public func setFullscreen(_ fullscreen: Bool) {
        kiln_wl_set_fullscreen(connection, fullscreen)
    }

    public func applyScale(logicalWidth: Int, logicalHeight: Int) {
        kiln_wl_set_buffer_scale120(connection, UInt32((scale * 120).rounded()), Int32(logicalWidth), Int32(logicalHeight))
    }

    public func setCursor(_ cursor: Cursor) {
        kiln_wl_set_cursor(connection, cursor.raw)
    }

    public func inhibitIdle(_ inhibit: Bool) {
        kiln_wl_inhibit_idle(connection, inhibit)
    }

    /// Raises and focuses the window with a launcher's xdg-activation token.
    @discardableResult
    public func activate(token: String) -> Bool {
        kiln_wl_activate(connection, token)
    }

    public func close() {
        kiln_wl_disconnect(connection)
    }

    /// Runs `body` on the main actor with the window a C callback's context points at. The pointer travels as an integer
    /// because every callback arrives on the main thread, inside `pump`.
    private nonisolated static func on(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (WaylandWindow) -> Void) {
        let address = UInt(bitPattern: context)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
            body(Unmanaged<WaylandWindow>.fromOpaque(pointer).takeUnretainedValue())
        }
    }

    private static let callbacks = kiln_wl_callbacks(
        configure: { context, width, height, states in
            WaylandWindow.on(context) { window in
                if width > 0 { window.width = Int(width) }
                if height > 0 { window.height = Int(height) }
                if window.width == 0 { window.width = 1280 }
                if window.height == 0 { window.height = 800 }
                let fullscreen = states & UInt32(KILN_STATE_FULLSCREEN) != 0
                window.delegate?.windowConfigured(window, width: window.width, height: window.height, fullscreen: fullscreen)
            }
        },
        close: { context in
            WaylandWindow.on(context) { window in
                window.delegate?.windowClosed(window)
            }
        },
        scale: { context, scale120 in
            WaylandWindow.on(context) { window in
                window.scale = Double(scale120) / 120
                window.delegate?.windowScaleChanged(window, scale: window.scale)
            }
        },
        presented: { context, nanoseconds, refresh, sequence, _ in
            WaylandWindow.on(context) { window in
                window.delegate?.windowPresented(window, nanoseconds: nanoseconds, refreshNanoseconds: refresh, sequence: sequence)
            }
        },
        discarded: { _ in },
        frame: { context, _ in
            WaylandWindow.on(context) { window in
                window.delegate?.windowFrameDone(window)
            }
        },
        pointer_motion: { context, x, y in
            WaylandWindow.on(context) { window in
                window.delegate?.windowPointerMoved(window, x: x, y: y)
            }
        },
        pointer_leave: { context in
            WaylandWindow.on(context) { window in
                window.delegate?.windowPointerLeft(window)
            }
        },
        pointer_button: { context, button, pressed in
            WaylandWindow.on(context) { window in
                window.delegate?.windowPointerButton(window, button: button, pressed: pressed != 0)
            }
        },
        pointer_axis: { context, frame in
            WaylandWindow.on(context) { window in
                let source: ScrollEvent.Source = switch frame.source {
                case 0: .wheel
                case 1: .finger
                case 2: .continuous
                default: .wheelTilt
                }
                let event = ScrollEvent(dx: Float(frame.dx), dy: Float(frame.dy), notchesX: Float(frame.dx120) / 120,
                                        notchesY: Float(frame.dy120) / 120, source: frame.dx120 != 0 || frame.dy120 != 0 ? .wheel : source,
                                        ended: frame.stop_x || frame.stop_y, timeMilliseconds: frame.time_ms)
                window.delegate?.windowScrolled(window, event: event)
            }
        },
        key: { context, key in
            WaylandWindow.on(context) { window in
                let text = withUnsafeBytes(of: key.text) { buffer in
                    String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
                }
                let event = KeyEvent(key: Key(key.keysym), text: text, modifiers: Modifiers(rawValue: key.modifiers))
                window.delegate?.windowKey(window, event: event, pressed: key.pressed, repeats: key.repeats)
            }
        },
        modifiers: { context, mask in
            WaylandWindow.on(context) { window in
                window.delegate?.windowModifiersChanged(window, modifiers: Modifiers(rawValue: mask))
            }
        },
        repeat_info: { context, rate, delay in
            WaylandWindow.on(context) { window in
                window.delegate?.windowRepeatInfo(window, rate: rate, delay: delay)
            }
        },
        keyboard_focus: { context, focused in
            WaylandWindow.on(context) { window in
                window.delegate?.windowKeyboardFocusChanged(window, focused: focused)
            }
        }
    )
}
