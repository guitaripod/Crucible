import CKiln
import Foundation

/// KWin's screens as Match Content changes them (kde_output_management_v2), on a Wayland connection of its own: a screen's
/// modes, HDR and wide colour gamut, and switching them. Every call blocks until KWin answers, so it is used off the main
/// thread, one call at a time.
public final class DisplayControl: @unchecked Sendable {
    public struct Mode: Equatable, Sendable, Codable {
        public var width: Int
        public var height: Int
        public var refreshMilliHertz: Int

        public init(width: Int, height: Int, refreshMilliHertz: Int) {
            self.width = width
            self.height = height
            self.refreshMilliHertz = refreshMilliHertz
        }
    }

    public struct State: Equatable, Sendable {
        public var current: Mode
        public var modes: [Mode]
        public var hdrCapable: Bool
        public var hdr: Bool
        public var wideColorGamut: Bool
        /// The screen follows a fullscreen window's frame rate (variable refresh), so no refresh needs choosing.
        public var adaptiveSync: Bool = false
    }

    private let handle: OpaquePointer

    /// Connects to the compositor; nil when it has no output management (a compositor other than KWin).
    public init?() {
        guard let handle = kiln_display_open() else { return nil }
        self.handle = handle
    }

    deinit {
        kiln_display_close(handle)
    }

    public func state(of output: String) -> State? {
        var raw = kiln_display_state()
        guard kiln_display_read(handle, output, &raw) else { return nil }
        let modes = withUnsafeBytes(of: raw.modes) { buffer in
            Array(buffer.bindMemory(to: kiln_display_mode.self).prefix(Int(raw.mode_count))).map(Self.mode)
        }
        return State(current: Self.mode(raw.current), modes: modes, hdrCapable: raw.hdr_capable, hdr: raw.hdr, wideColorGamut: raw.wide_color_gamut,
                     adaptiveSync: raw.adaptive_sync)
    }

    /// Switches `output` to `mode` and to HDR and wide colour gamut as given; nil keeps each as it is. True once KWin applied
    /// it, or when nothing needed to change.
    @discardableResult
    public func apply(to output: String, mode: Mode?, hdr: Bool?, wideColorGamut: Bool?) -> Bool {
        let raw = mode.map { kiln_display_mode(width: Int32($0.width), height: Int32($0.height), refresh: Int32($0.refreshMilliHertz)) }
            ?? kiln_display_mode(width: 0, height: 0, refresh: 0)
        return kiln_display_apply(handle, output, raw, hdr.map { $0 ? 1 : 0 } ?? -1, wideColorGamut.map { $0 ? 1 : 0 } ?? -1)
    }

    private static func mode(_ raw: kiln_display_mode) -> Mode {
        Mode(width: Int(raw.width), height: Int(raw.height), refreshMilliHertz: Int(raw.refresh))
    }
}
