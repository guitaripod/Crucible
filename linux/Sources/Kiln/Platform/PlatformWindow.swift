import CKiln
import Foundation

/// What the window reports back to its owner, on the main actor.
@MainActor
public protocol PlatformWindowDelegate: AnyObject {
    func windowConfigured(_ window: PlatformWindow, width: Int, height: Int, fullscreen: Bool)
    func windowClosed(_ window: PlatformWindow)
    func windowScaleChanged(_ window: PlatformWindow, scale: Double)
    func windowPresented(_ window: PlatformWindow, nanoseconds: UInt64, refreshNanoseconds: UInt32, sequence: UInt64)
    func windowFrameDone(_ window: PlatformWindow)
    func windowPointerMoved(_ window: PlatformWindow, x: Double, y: Double)
    func windowPointerLeft(_ window: PlatformWindow)
    func windowPointerButton(_ window: PlatformWindow, button: UInt32, pressed: Bool)
    func windowScrolled(_ window: PlatformWindow, event: ScrollEvent)
    func windowKey(_ window: PlatformWindow, event: KeyEvent, pressed: Bool, repeats: Bool)
    func windowModifiersChanged(_ window: PlatformWindow, modifiers: Modifiers)
    func windowRepeatInfo(_ window: PlatformWindow, rate: Int32, delay: Int32)
    func windowKeyboardFocusChanged(_ window: PlatformWindow, focused: Bool)
    func windowTextInput(_ window: PlatformWindow, event: TextInputEvent)
}

extension PlatformWindowDelegate {
    public func windowModifiersChanged(_ window: PlatformWindow, modifiers: Modifiers) {}
    public func windowRepeatInfo(_ window: PlatformWindow, rate: Int32, delay: Int32) {}
    public func windowKeyboardFocusChanged(_ window: PlatformWindow, focused: Bool) {}
    public func windowTextInput(_ window: PlatformWindow, event: TextInputEvent) {}
}

/// A toplevel on the desktop's display server: a Wayland toplevel (`WaylandWindow`) everywhere it can be shown, and an X11
/// window (`X11Window`) under gamescope in Steam's Game Mode. Both report through the same C callbacks; what one of them
/// cannot do (an X11 window has no colour management, input method or clipboard) answers as a compositor without it would.
@MainActor
public class PlatformWindow {
    public weak var delegate: PlatformWindowDelegate?
    public internal(set) var width = 0
    public internal(set) var height = 0
    public internal(set) var scale = 1.0

    /// The window the current session shows: X11 under gamescope (Steam lets only XWayland windows take focus there), and
    /// otherwise Wayland, or X11 on a desktop without it. `KILN_BACKEND=x11|wayland` decides instead.
    public static func makeForSession(environment: [String: String] = ProcessInfo.processInfo.environment) -> PlatformWindow? {
        switch environment["KILN_BACKEND"]?.lowercased() {
        case "x11": return X11Window()
        case "wayland": return WaylandWindow()
        default: break
        }
        let hasX11 = !(environment["DISPLAY"] ?? "").isEmpty
        if hasX11 && environment["GAMESCOPE_WAYLAND_DISPLAY"] != nil, let window = X11Window() { return window }
        if let window = WaylandWindow() { return window }
        return hasX11 ? X11Window() : nil
    }

    public var fileDescriptor: Int32 { -1 }
    /// Another connection the window reads events from, which `pump` also handles; nil when it has none.
    public var secondaryFileDescriptor: Int32? { nil }

    public func open(title: String, appID: String, delegate: PlatformWindowDelegate) -> Bool { false }

    /// The GPU device with a swapchain on this window.
    public func makeGPU() throws(RenderError) -> GPU {
        throw .device("no window")
    }

    public func pump(readable: Bool) -> Bool { false }
    public func flush() {}

    /// What the compositor prefers for the window (`DisplayColor`), or nil without color management.
    public func readDisplayColor() -> DisplayColor? { nil }
    /// Moves each time the compositor says its preferred description changed.
    public var displayColorSerial: UInt32 { 0 }
    /// What the swapchain's light is multiplied by so the window's reference white lands where the compositor shows the
    /// rest of the system's (gamescope scales HDR and SDR content by different gains), and whether the compositor wants SDR
    /// buffers; both as of the last `readDisplayColor`.
    public var outputGain: Float { 1 }
    public var prefersSDROutput: Bool { false }
    /// The screen's refresh period when the window knows it before any frame is shown (X11 reads it from RandR; Wayland
    /// learns it from presentation feedback).
    public var refreshNanoseconds: UInt32? { nil }
    /// The keyboard's repeat rate and delay as last reported, which an X11 window hears while it opens, before its owner
    /// listens.
    public internal(set) var keyRepeat: (rate: Int32, delay: Int32)?

    /// Asks to hear when the frame about to be presented has been taken (`windowFrameDone`).
    public func requestFrame() {}
    public func setFullscreen(_ fullscreen: Bool) {}

    /// Whether the window's buffers can be larger than it, cropped by `cropBuffer`.
    public var canCropBuffer: Bool { false }
    /// Shows only the top-left `width` by `height` pixels of the window's buffers, which must lie inside the next one.
    public func cropBuffer(width: Int, height: Int) {}
    public func applyScale(logicalWidth: Int, logicalHeight: Int) {}
    public func setCursor(_ cursor: Cursor) {}

    /// Keeps the screen awake over the window; false when the display server cannot.
    @discardableResult
    public func inhibitIdle(_ inhibit: Bool) -> Bool { false }

    @discardableResult
    public func setClipboard(_ text: String) -> Bool { false }
    @discardableResult
    public func setClipboard(_ data: Data, mimeType: String) -> Bool { false }
    public func clipboardText() -> String? { nil }

    /// The compositor's description of the screen the window is on.
    public var outputDescription: String? { nil }
    /// The name of the screen the window is on ("DP-3").
    public var outputName: String? { nil }
    /// The physical size of the screen the window is on, in millimetres, when the screen reports one.
    public var screenSizeMillimetres: (width: Int, height: Int)? { nil }

    public func setTextInputEnabled(_ enabled: Bool) {}
    public func updateTextInput(_ state: TextInputState, caret: Rect) {}

    @discardableResult
    public func activate(token: String) -> Bool { false }
    @discardableResult
    public func raise() -> Bool { false }
    public func close() {}

    /// Runs `body` on the main actor with the window a C callback's context points at. The pointer travels as an integer
    /// because every callback arrives on the main thread, inside `pump`.
    nonisolated static func on(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (PlatformWindow) -> Void) {
        let address = UInt(bitPattern: context)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
            body(Unmanaged<PlatformWindow>.fromOpaque(pointer).takeUnretainedValue())
        }
    }

    static let callbacks = kiln_wl_callbacks(
        configure: { context, width, height, states in
            PlatformWindow.on(context) { window in
                if width > 0 { window.width = Int(width) }
                if height > 0 { window.height = Int(height) }
                if window.width == 0 { window.width = 1280 }
                if window.height == 0 { window.height = 800 }
                let fullscreen = states & UInt32(KILN_STATE_FULLSCREEN) != 0
                window.delegate?.windowConfigured(window, width: window.width, height: window.height, fullscreen: fullscreen)
            }
        },
        close: { context in
            PlatformWindow.on(context) { window in
                window.delegate?.windowClosed(window)
            }
        },
        scale: { context, scale120 in
            PlatformWindow.on(context) { window in
                window.scale = Double(scale120) / 120
                window.delegate?.windowScaleChanged(window, scale: window.scale)
            }
        },
        presented: { context, nanoseconds, refresh, sequence, _ in
            PlatformWindow.on(context) { window in
                window.delegate?.windowPresented(window, nanoseconds: nanoseconds, refreshNanoseconds: refresh, sequence: sequence)
            }
        },
        discarded: { _ in },
        frame: { context, _ in
            PlatformWindow.on(context) { window in
                window.delegate?.windowFrameDone(window)
            }
        },
        pointer_motion: { context, x, y in
            PlatformWindow.on(context) { window in
                window.delegate?.windowPointerMoved(window, x: x, y: y)
            }
        },
        pointer_leave: { context in
            PlatformWindow.on(context) { window in
                window.delegate?.windowPointerLeft(window)
            }
        },
        pointer_button: { context, button, pressed in
            PlatformWindow.on(context) { window in
                window.delegate?.windowPointerButton(window, button: button, pressed: pressed != 0)
            }
        },
        pointer_axis: { context, frame in
            PlatformWindow.on(context) { window in
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
            PlatformWindow.on(context) { window in
                let text = withUnsafeBytes(of: key.text) { buffer in
                    String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
                }
                let event = KeyEvent(key: Key(key.keysym), text: text, modifiers: Modifiers(rawValue: key.modifiers))
                window.delegate?.windowKey(window, event: event, pressed: key.pressed, repeats: key.repeats)
            }
        },
        modifiers: { context, mask in
            PlatformWindow.on(context) { window in
                window.delegate?.windowModifiersChanged(window, modifiers: Modifiers(rawValue: mask))
            }
        },
        repeat_info: { context, rate, delay in
            PlatformWindow.on(context) { window in
                window.keyRepeat = (rate, delay)
                window.delegate?.windowRepeatInfo(window, rate: rate, delay: delay)
            }
        },
        keyboard_focus: { context, focused in
            PlatformWindow.on(context) { window in
                window.delegate?.windowKeyboardFocusChanged(window, focused: focused)
            }
        },
        text_input: { context, raw in
            let event = TextInputEvent(raw)
            PlatformWindow.on(context) { window in
                window.delegate?.windowTextInput(window, event: event)
            }
        }
    )
}
