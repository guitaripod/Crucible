import CLinuxServices
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Keeps the screen awake while something plays: the compositor's idle inhibit, or org.freedesktop.ScreenSaver where the
/// compositor has none (gamescope).
@MainActor
enum ScreenAwake {
    private static var holdsScreenSaver = false

    static func hold(_ awake: Bool, in window: Window?) {
        if awake {
            if window?.inhibitIdle(true) == true { return }
            holdsScreenSaver = crucible_screensaver_inhibit("Playing video")
            if !holdsScreenSaver { MidgarLog.error("Neither the compositor nor the screen saver can keep the screen awake", category: .playback) }
        } else {
            window?.inhibitIdle(false)
            guard holdsScreenSaver else { return }
            crucible_screensaver_uninhibit()
            holdsScreenSaver = false
        }
    }
}

/// Lets go of decoded artwork nothing on screen shows when the kernel reports memory running short (a pressure-stall
/// trigger), as the Apple TV does on a memory warning; at most once every ten seconds, and not while the app is still
/// starting, when reading its own files from disk stalls like pressure does.
@MainActor
final class MemoryPressure {
    private static let spacing: Duration = .seconds(10)
    private static let startupGrace: Duration = .seconds(20)
    private let fd: Int32
    private let started = ContinuousClock.now
    private var lastPurge: ContinuousClock.Instant?

    init?(loop: EventLoop, window: Window) {
        fd = crucible_memory_pressure_open()
        guard fd >= 0 else { return nil }
        loop.add(urgentFD: fd) { [weak self, weak window] urgent in
            guard urgent, let self, let window else { return }
            self.purge(window)
        }
    }

    private func purge(_ window: Window) {
        let now = ContinuousClock.now
        guard started.duration(to: now) >= Self.startupGrace else { return }
        if let lastPurge, lastPurge.duration(to: now) < Self.spacing { return }
        lastPurge = now
        MidgarLog.notice("Memory is short: purging decoded artwork", category: .lifecycle)
        window.purgeImageMemory()
    }
}

/// The desktop's Reduce Motion and contrast settings, read through the settings portal (docs/LINUX.md section 5): reduced
/// motion (the portal's own key, GNOME's animations switch or KDE's animation speed at instant) makes every change apply at
/// once, and high contrast turns glass into the opaque raised surface, as Reduce Transparency does on the Apple TV.
/// `CRUCIBLE_REDUCE_MOTION` and `CRUCIBLE_REDUCE_TRANSPARENCY` set to 1 or 0 override them, for headless checks.
@MainActor
enum DesktopAccessibility {
    static func apply(to window: Window?) {
        let motion = reducesMotion
        let transparency = reducesTransparency
        guard motion != Animation.reduceMotion || transparency != Theme.current.reduceTransparency else { return }
        Animation.reduceMotion = motion
        if transparency != Theme.current.reduceTransparency { Theme.current.reduceTransparency = transparency }
        MidgarLog.notice("Desktop settings: reduce motion \(motion), reduce transparency \(transparency)", category: .lifecycle)
        window?.setNeedsDisplay()
    }

    private static var reducesMotion: Bool {
        if let forced = override("CRUCIBLE_REDUCE_MOTION") { return forced }
        if setting("org.freedesktop.appearance", "reduced-motion") == 1 { return true }
        if setting("org.gnome.desktop.interface", "enable-animations") == 0 { return true }
        if setting("org.kde.kdeglobals.KDE", "AnimationDurationFactor") == 0 { return true }
        return false
    }

    private static var reducesTransparency: Bool {
        if let forced = override("CRUCIBLE_REDUCE_TRANSPARENCY") { return forced }
        return setting("org.freedesktop.appearance", "contrast") == 1
    }

    private static func override(_ name: String) -> Bool? {
        ProcessInfo.processInfo.environment[name].map { $0 == "1" }
    }

    private static func setting(_ namespace: String, _ key: String) -> Double? {
        var value = 0.0
        return crucible_portal_setting(namespace, key, &value) ? value : nil
    }
}
