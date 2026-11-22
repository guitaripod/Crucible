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
/// starting, when reading its own files from disk stalls like pressure does. The trigger is system-wide, so a stall that
/// leaves plenty of memory available (another program swapping in, a full disk's writeback, as on a Steam Deck under
/// Steam) is not taken as a warning: artwork thrown away then only costs decoding it again.
@MainActor
final class MemoryPressure {
    private static let spacing: Duration = .seconds(10)
    private static let startupGrace: Duration = .seconds(20)
    private let fd: Int32
    private let started = ContinuousClock.now
    private var lastPurge: ContinuousClock.Instant?

    /// Watches the kernel's pressure trigger and purges every window `windows` lists.
    init?(loop: EventLoop, windows: @escaping @MainActor () -> [Window]) {
        fd = crucible_memory_pressure_open()
        guard fd >= 0 else { return nil }
        loop.add(urgentFD: fd) { [weak self] urgent in
            guard urgent, let self else { return }
            self.purge(windows())
        }
    }

    private func purge(_ windows: [Window]) {
        let now = ContinuousClock.now
        guard started.duration(to: now) >= Self.startupGrace else { return }
        if let lastPurge, lastPurge.duration(to: now) < Self.spacing { return }
        guard Self.isMemoryShort() else { return }
        lastPurge = now
        MidgarLog.notice("Memory is short: purging decoded artwork", category: .lifecycle)
        windows.forEach { $0.purgeImageMemory() }
    }

    /// Whether less than a tenth of memory (and under 1.5 GB) is available, from /proc/meminfo; true when it cannot be read.
    static func isMemoryShort(meminfo: String? = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8)) -> Bool {
        guard let meminfo else { return true }
        func kilobytes(_ key: String) -> Double? {
            guard let line = meminfo.split(separator: "\n").first(where: { $0.hasPrefix(key + ":") }) else { return nil }
            return line.split(separator: " ").dropFirst().first.flatMap { Double($0) }
        }
        guard let total = kilobytes("MemTotal"), let available = kilobytes("MemAvailable"), total > 0 else { return true }
        return available < total * 0.1 && available < 1_572_864
    }
}

/// Rereads the desktop's settings the moment the settings portal says one changed, such as the desktop switching between
/// light and dark, instead of waiting for the window to be focused again.
@MainActor
final class DesktopSettingsWatch {
    private let handle: OpaquePointer
    private static var windows: @MainActor () -> [Window] = { [] }

    init?(loop: EventLoop, windows: @escaping @MainActor () -> [Window]) {
        guard let handle = crucible_portal_watch_create(DesktopSettingsWatch.handler, nil) else { return nil }
        self.handle = handle
        DesktopSettingsWatch.windows = windows
        loop.add(fd: crucible_portal_watch_fd(handle)) { _ in crucible_portal_watch_process(handle) }
    }

    private static let handler: crucible_portal_watch_handler = { _, _, _ in
        MainActor.assumeIsolated {
            DesktopAccessibility.apply(to: DesktopSettingsWatch.windows().first)
        }
    }
}

/// The desktop's Reduce Motion and contrast settings, read through the settings portal (docs/LINUX.md section 5): reduced
/// motion (the portal's own key, GNOME's animations switch or KDE's animation speed at instant) makes every change apply at
/// once, and high contrast turns glass into the opaque raised surface, as Reduce Transparency does on the Apple TV. The
/// portal is asked on a queue of its own, so a slow or missing portal never holds the window.
/// The text scaling factor scales the type recipes, as Dynamic Type does, up to 1.3. `CRUCIBLE_REDUCE_MOTION` and
/// `CRUCIBLE_REDUCE_TRANSPARENCY` set to 1 or 0, and `CRUCIBLE_TEXT_SCALE`, override them, for headless checks.
@MainActor
enum DesktopAccessibility {
    private struct Settings: Sendable {
        var reducesMotion: Bool
        var reducesTransparency: Bool
        var textScale: Float
        var prefersLight: Bool?
    }

    private static let portal = DispatchQueue(label: "crucible.portal-settings")

    static func apply(to window: Window?) {
        portal.async {
            let settings = read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { use(settings, in: window) }
            }
        }
    }

    /// The desktop's light or dark style, asked at launch before the first frame so it never flashes the other one; nil
    /// when the portal does not say.
    static func systemPrefersLight() -> Bool? {
        portal.sync { prefersLight }
    }

    private static func use(_ settings: Settings, in window: Window?) {
        if let prefersLight = settings.prefersLight { LinuxDisplay.systemStyleChanged(prefersLight: prefersLight, in: window) }
        let theme = Theme.current
        guard settings.reducesMotion != Animation.reduceMotion || settings.reducesTransparency != theme.reduceTransparency
            || settings.textScale != theme.textScale else { return }
        Animation.reduceMotion = settings.reducesMotion
        if settings.reducesTransparency != theme.reduceTransparency { theme.reduceTransparency = settings.reducesTransparency }
        if settings.textScale != theme.textScale {
            theme.textScale = settings.textScale
            window?.relayoutEverything()
        }
        MidgarLog.notice("Desktop settings: reduce motion \(settings.reducesMotion), reduce transparency \(settings.reducesTransparency), text \(settings.textScale)×",
                         category: .lifecycle)
        window?.setNeedsDisplay()
    }

    private nonisolated static func read() -> Settings {
        Settings(reducesMotion: reducesMotion, reducesTransparency: reducesTransparency, textScale: textScale, prefersLight: prefersLight)
    }

    /// The portal's `color-scheme`: 1 prefers dark, 2 prefers light, 0 has no preference, which Crucible draws dark.
    /// `CRUCIBLE_COLOR_SCHEME` set to light or dark overrides it, for headless checks.
    private nonisolated static var prefersLight: Bool? {
        if let forced = ProcessInfo.processInfo.environment["CRUCIBLE_COLOR_SCHEME"] { return forced == "light" }
        return setting("org.freedesktop.appearance", "color-scheme").map { $0 == 2 }
    }

    /// GNOME's text scaling factor (the portal answers it on other desktops too), within what the layouts are built for.
    private nonisolated static var textScale: Float {
        if let forced = ProcessInfo.processInfo.environment["CRUCIBLE_TEXT_SCALE"].flatMap(Float.init) { return forced }
        guard let factor = setting("org.gnome.desktop.interface", "text-scaling-factor") else { return 1 }
        return min(max(Float(factor), 1), 1.3)
    }

    private nonisolated static var reducesMotion: Bool {
        if let forced = override("CRUCIBLE_REDUCE_MOTION") { return forced }
        if setting("org.freedesktop.appearance", "reduced-motion") == 1 { return true }
        if setting("org.gnome.desktop.interface", "enable-animations") == 0 { return true }
        if setting("org.kde.kdeglobals.KDE", "AnimationDurationFactor") == 0 { return true }
        return false
    }

    private nonisolated static var reducesTransparency: Bool {
        if let forced = override("CRUCIBLE_REDUCE_TRANSPARENCY") { return forced }
        return setting("org.freedesktop.appearance", "contrast") == 1
    }

    private nonisolated static func override(_ name: String) -> Bool? {
        ProcessInfo.processInfo.environment[name].map { $0 == "1" }
    }

    private nonisolated static func setting(_ namespace: String, _ key: String) -> Double? {
        var value = 0.0
        return crucible_portal_setting(namespace, key, &value) ? value : nil
    }
}
