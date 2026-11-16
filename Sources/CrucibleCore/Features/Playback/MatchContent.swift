import Foundation

/// A screen mode as the compositor lists it: its size in pixels and its refresh rate in millihertz.
package struct DisplayMode: Equatable, Sendable {
    package var width: Int
    package var height: Int
    package var refreshMilliHertz: Int

    package init(width: Int, height: Int, refreshMilliHertz: Int) {
        self.width = width
        self.height = height
        self.refreshMilliHertz = refreshMilliHertz
    }
}

/// What Match Content asks of the screen for a title (docs/LINUX.md §7.4, Linux): HDR for an HDR picture when the screen
/// can show it, and a refresh rate that shows every frame for the same time, a whole number of refreshes each, among the
/// modes at the screen's current size. 23.976 and 29.97 fps go to 119.88 Hz and 25 and 50 fps to 100 Hz where those
/// modes exist, and 24 fps stays on 144 Hz, six refreshes a frame. Nothing changes that already fits, and a screen with
/// variable refresh on (it follows the fullscreen player's frame rate) keeps its mode, so it never goes black for the
/// refresh; only HDR still switches there.
package struct MatchContentPlan: Equatable, Sendable {
    /// The refresh to switch to at the current size, nil to keep the current one.
    package var refreshMilliHertz: Int?
    /// HDR to turn on, nil to leave it as it is.
    package var hdr: Bool?

    package var changesNothing: Bool { refreshMilliHertz == nil && hdr == nil }

    /// How close a refresh has to come to a whole multiple of the frame rate.
    private static let tolerance = 0.0005

    package static func make(frameRate: Double?, isHDR: Bool, current: DisplayMode, modes: [DisplayMode], hdrCapable: Bool,
                             hdrOn: Bool, adaptiveSync: Bool = false) -> MatchContentPlan {
        let hdr: Bool? = isHDR && hdrCapable && !hdrOn ? true : nil
        guard let frameRate, frameRate > 1, !adaptiveSync, !fits(current.refreshMilliHertz, frameRate) else {
            return MatchContentPlan(refreshMilliHertz: nil, hdr: hdr)
        }
        let fitting = modes.filter { $0.width == current.width && $0.height == current.height && fits($0.refreshMilliHertz, frameRate) }
        let best = fitting.map(\.refreshMilliHertz).max()
        return MatchContentPlan(refreshMilliHertz: best == current.refreshMilliHertz ? nil : best, hdr: hdr)
    }

    /// Whether a refresh shows each frame a whole number of times.
    static func fits(_ refreshMilliHertz: Int, _ frameRate: Double) -> Bool {
        let ratio = Double(refreshMilliHertz) / 1000 / frameRate
        let whole = ratio.rounded()
        return whole >= 1 && abs(ratio - whole) / whole <= tolerance
    }
}

extension Preferences {
    private static let matchContentKey = "linux.matchContent"

    /// Whether the player switches the screen to the title's frame rate and dynamic range while it fills the screen.
    package static var matchesContent: Bool {
        get { UserDefaults.standard.object(forKey: matchContentKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: matchContentKey) }
    }
}
