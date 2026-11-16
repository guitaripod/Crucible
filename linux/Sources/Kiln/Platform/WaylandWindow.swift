import CKiln
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// One xdg toplevel on its own Wayland connection, with the colour, timing and scale protocols Kiln relies on.
@MainActor
public final class WaylandWindow: PlatformWindow {
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

    private let connection: OpaquePointer

    public init?(displayName: String? = nil) {
        guard let connection = kiln_wl_connect(displayName) else { return nil }
        self.connection = connection
    }

    public override var fileDescriptor: Int32 { kiln_wl_fd(connection) }
    public var display: OpaquePointer? { kiln_wl_display(connection) }
    public var surface: OpaquePointer? { kiln_wl_surface(connection) }
    public var colorSupport: ColorSupport { ColorSupport(rawValue: kiln_wl_color_features(connection)) }

    public override func open(title: String, appID: String, delegate: PlatformWindowDelegate) -> Bool {
        self.delegate = delegate
        let context = Unmanaged.passUnretained(self).toOpaque()
        return kiln_wl_create_window(connection, title, appID, Self.callbacks, context)
    }

    public override func makeGPU() throws(RenderError) -> GPU {
        try GPU(display: display, surface: surface)
    }

    public override func pump(readable: Bool) -> Bool {
        kiln_wl_pump(connection, readable) == 0
    }

    public override func flush() {
        _ = kiln_wl_flush(connection)
    }

    public func describeAsScRGB() -> Bool {
        kiln_wl_describe_scrgb(connection)
    }

    /// What the compositor prefers for the window (`DisplayColor`), or nil without color management.
    public override func readDisplayColor() -> DisplayColor? {
        var raw = kiln_display_color()
        guard kiln_wl_display_color(connection, &raw) else { return nil }
        return DisplayColor(transfer: raw.transfer, minimum: raw.min_luminance, maximum: raw.max_luminance, reference: raw.reference_luminance,
                            targetMinimum: raw.target_min_luminance, targetMaximum: raw.target_max_luminance, targetMaxCLL: raw.target_max_cll)
    }

    /// Moves each time the compositor says its preferred description changed.
    public override var displayColorSerial: UInt32 { kiln_wl_display_color_serial(connection) }

    public override func requestFrame() {
        kiln_wl_request_frame(connection)
    }

    public override func setFullscreen(_ fullscreen: Bool) {
        kiln_wl_set_fullscreen(connection, fullscreen)
    }

    /// Whether the window's buffers can be larger than it, cropped by `cropBuffer`.
    public override var canCropBuffer: Bool {
        kiln_wl_can_crop_buffer(connection)
    }

    /// Shows only the top-left `width` by `height` pixels of the window's buffers, which must lie inside the next one.
    public override func cropBuffer(width: Int, height: Int) {
        kiln_wl_crop_buffer(connection, Int32(width), Int32(height))
    }

    public override func applyScale(logicalWidth: Int, logicalHeight: Int) {
        kiln_wl_set_buffer_scale120(connection, UInt32((scale * 120).rounded()), Int32(logicalWidth), Int32(logicalHeight))
    }

    public override func setCursor(_ cursor: Cursor) {
        kiln_wl_set_cursor(connection, cursor.raw)
    }

    @discardableResult
    public override func inhibitIdle(_ inhibit: Bool) -> Bool {
        kiln_wl_inhibit_idle(connection, inhibit)
    }

    /// Makes `text` the clipboard.
    @discardableResult
    public override func setClipboard(_ text: String) -> Bool {
        kiln_wl_set_clipboard(connection, text)
    }

    /// Makes `data` of type `mimeType` ("image/png") the clipboard.
    @discardableResult
    public override func setClipboard(_ data: Data, mimeType: String) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return kiln_wl_set_clipboard_data(connection, mimeType, base, buffer.count)
        }
    }

    /// The clipboard's text, or nil when it holds none.
    public override func clipboardText() -> String? {
        guard let raw = kiln_wl_clipboard_text(connection) else { return nil }
        defer { free(raw) }
        return String(cString: raw)
    }

    /// The name of the screen the window is on ("DP-3").
    public override var outputDescription: String? {
        kiln_wl_output_description(connection).map { String(cString: $0) }
    }

    public override var outputName: String? {
        kiln_wl_output_name(connection).map { String(cString: $0) }
    }

    /// The physical size of the screen the window is on, in millimetres, when the screen reports one.
    public override var screenSizeMillimetres: (width: Int, height: Int)? {
        var width: Int32 = 0
        var height: Int32 = 0
        guard kiln_wl_output_size_mm(connection, &width, &height) else { return nil }
        return (Int(width), Int(height))
    }

    /// Turns the input method on for a focused text field, or off.
    public override func setTextInputEnabled(_ enabled: Bool) {
        kiln_wl_text_input_enable(connection, enabled)
    }

    /// Tells the input method the focused field's text, caret and purpose; `caret` is in surface points.
    public override func updateTextInput(_ state: TextInputState, caret: Rect) {
        let type = state.contentType
        let shown = state.purpose == .password ? "" : state.text
        let cursor = state.purpose == .password ? 0 : state.cursor
        let anchor = state.purpose == .password ? 0 : state.anchor
        kiln_wl_text_input_update(connection, shown, Int32(cursor), Int32(anchor), Int32(caret.minX.rounded()), Int32(caret.minY.rounded()),
                                  Int32(max(caret.width.rounded(), 1)), Int32(max(caret.height.rounded(), 1)), type.hint, type.purpose)
    }

    /// Raises and focuses the window with a launcher's xdg-activation token.
    @discardableResult
    public override func activate(token: String) -> Bool {
        kiln_wl_activate(connection, token)
    }

    /// Raises and focuses the window without a launcher's token, as far as the compositor's focus rules allow.
    @discardableResult
    public override func raise() -> Bool {
        kiln_wl_raise(connection)
    }

    public override func close() {
        kiln_wl_disconnect(connection)
    }
}
