import CKiln
import Foundation

/// A full-screen X11 window, for gamescope in Steam's Game Mode: Steam gives focus only to the windows XWayland reports, so
/// a Wayland toplevel there runs unseen behind Steam's launch screen. The window carries the game's Steam app ID
/// (`STEAM_GAME`) so gamescope and Steam know it as the launched title, and gamescope's WSI layer takes its Vulkan
/// swapchain straight to the compositor. X11 sends no frame callbacks, so a presented frame counts as taken once the FIFO
/// swapchain has accepted it.
@MainActor
public final class X11Window: PlatformWindow {
    private let connection: OpaquePointer
    private var frameRequested = false
    private var gain: Float = 1
    private var sdr = false
    private var refresh: UInt32?

    public init?(displayName: String? = nil) {
        guard let connection = kiln_x11_connect(displayName) else { return nil }
        self.connection = connection
    }

    public override var fileDescriptor: Int32 { kiln_x11_fd(connection) }
    /// gamescope's root XWayland server, where Steam sets the brightness and HDR state, once the first colour reading
    /// opened it.
    public override var secondaryFileDescriptor: Int32? {
        let fd = kiln_x11_root_fd(connection)
        return fd >= 0 ? fd : nil
    }

    public override func open(title: String, appID: String, delegate: PlatformWindowDelegate) -> Bool {
        self.delegate = delegate
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard kiln_x11_create_window(connection, title, appID, Self.steamAppID(), Self.callbacks, context) else { return false }
        let millihertz = kiln_x11_refresh_millihertz(connection)
        refresh = millihertz > 1000 ? UInt32(1_000_000_000_000 / UInt64(millihertz)) : nil
        return true
    }

    public override var refreshNanoseconds: UInt32? { refresh }

    public override var displayColorSerial: UInt32 { kiln_x11_color_serial(connection) }
    public override var outputGain: Float { gain }
    public override var prefersSDROutput: Bool { sdr }

    /// gamescope's composition as Steam set it. On an HDR output, gamescope shows SDR content (Steam's own interface) at
    /// `sdr_on_hdr_nits` times the SDR gain and multiplies HDR content by the HDR gain, so Kiln's 203 cd/m² reference white is
    /// scaled to land exactly where Steam's white does, and the panel's peak above it stays for HDR video. On an SDR output
    /// the window draws SDR, as Steam does, so the brightness slider treats both alike. Outside gamescope there is nothing to
    /// read.
    public override func readDisplayColor() -> DisplayColor? {
        drained(gamescopeColor())
    }

    private func gamescopeColor() -> DisplayColor? {
        var raw = kiln_gamescope_color()
        guard kiln_x11_gamescope_color(connection, &raw) else {
            gain = 1
            sdr = false
            return nil
        }
        let reference = 203.0
        guard raw.hdr else {
            gain = 1
            sdr = true
            return DisplayColor(transfer: 2, minimum: 0, maximum: reference, reference: reference)
        }
        let systemWhite = Double(raw.sdr_on_hdr_nits * raw.sdr_gain)
        let scale = systemWhite / (reference * Double(raw.hdr_gain))
        gain = Float(scale)
        sdr = false
        let panel = raw.display_nits > 0 ? Double(raw.display_nits) : 1000
        return DisplayColor(transfer: 5, minimum: 0, maximum: panel / (scale * Double(raw.hdr_gain)), reference: reference)
    }

    /// Reads gamescope's state, then handles the events the connection queued while it waited for those replies, which the
    /// socket will not announce again.
    private func drained(_ color: DisplayColor?) -> DisplayColor? {
        _ = kiln_x11_pump(connection)
        return color
    }

    public override func makeGPU() throws(RenderError) -> GPU {
        try GPU(xcbConnection: kiln_x11_connection(connection), window: kiln_x11_window(connection))
    }

    public override func pump(readable: Bool) -> Bool {
        kiln_x11_pump(connection) == 0
    }

    public override func requestFrame() {
        frameRequested = true
    }

    /// Sends the requests made since the last pump; a frame that was just presented is reported taken on the next turn.
    public override func flush() {
        kiln_x11_flush(connection)
        guard frameRequested else { return }
        frameRequested = false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.windowFrameDone(self)
            }
        }
    }

    public override func setFullscreen(_ fullscreen: Bool) {
        kiln_x11_set_fullscreen(connection, fullscreen)
    }

    public override func setCursor(_ cursor: Cursor) {
        kiln_x11_set_cursor(connection, cursor.raw)
    }

    public override func close() {
        kiln_x11_disconnect(connection)
    }

    /// The Steam app ID the process was launched under: the systemd scope Steam starts every title in
    /// (`app-steam-app<ID>-<PID>.scope`, as gamescope reads it), else `SteamAppId`; 0 outside Steam.
    static func steamAppID(cgroup: String? = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8),
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt32 {
        if let cgroup, let range = cgroup.range(of: "app-steam-app") {
            let digits = cgroup[range.upperBound...].prefix { $0.isNumber }
            if let id = UInt32(digits), id != 0 { return id }
        }
        if let id = environment["SteamAppId"].flatMap(UInt32.init), id != 0 { return id }
        return 0
    }
}
