import CLinuxServices
import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The systemd user timer that checks the server for news while Crucible is closed: every half hour it runs
/// `crucible --check-news`, which announces what arrived and opens a title when its notification is clicked. The app
/// writes the units for its own executable and turns the timer on or off with the switches in Settings › Notifications.
@MainActor
enum NewsTimer {
    private nonisolated static let name = "crucible-news"

    private static var directory: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("systemd/user", isDirectory: true)
    }

    /// Whether the timer should run: news notifications are on, the closed-app check is on, and a real server is signed in.
    static var isWanted: Bool {
        Preferences.notifiesWhileClosed && (Preferences.notifies(.newEpisodes) || Preferences.notifies(.watchlistArrivals))
            && !DemoMode.shared.isActive && ServerBootstrap.connection() != nil
    }

    /// Brings the units and the timer in line with the settings, off the main thread; headless runs leave the desktop alone.
    static func sync() {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_NO_BROWSER"] != "1" else { return }
        let wanted = isWanted
        let executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().path
        let directory = directory
        Task.detached(priority: .utility) {
            if wanted {
                guard writeUnits(executable: executable, in: directory) else { return }
                systemctl(["daemon-reload"])
                systemctl(["enable", "--now", "\(name).timer"])
            } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).timer").path) {
                systemctl(["disable", "--now", "\(name).timer"])
            }
        }
    }

    /// Writes the service and timer units when they differ from what is there; returns whether they are in place.
    private nonisolated static func writeUnits(executable: String, in directory: URL) -> Bool {
        let service = """
        [Unit]
        Description=Crucible: announce what arrived on your Plex server

        [Service]
        Type=oneshot
        ExecStart="\(executable)" --check-news
        TimeoutStartSec=15min

        """
        let timer = """
        [Unit]
        Description=Crucible: check your Plex server for new episodes and watchlist arrivals

        [Timer]
        OnBootSec=10min
        OnUnitInactiveSec=30min
        RandomizedDelaySec=2min

        [Install]
        WantedBy=timers.target

        """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (file, text) in [("\(name).service", service), ("\(name).timer", timer)] {
                let url = directory.appendingPathComponent(file)
                guard (try? String(contentsOf: url, encoding: .utf8)) != text else { continue }
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            MidgarLog.error("Writing the news timer failed: \(error.localizedDescription)", category: .lifecycle)
            return false
        }
    }

    private nonisolated static func systemctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemctl")
        process.arguments = ["--user"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            MidgarLog.error("systemctl --user \(arguments.joined(separator: " ")) failed: \(error.localizedDescription)", category: .lifecycle)
        }
    }
}

/// `crucible --check-news`, which the timer runs: one look at the server for news while the app is closed. A notification
/// waits a while for its click, which opens the title in Crucible, starting it when it is still closed.
@MainActor
enum ClosedNewsCheck {
    /// How long a click on a notification can still open its title.
    private static let clickWindow: TimeInterval = 10 * 60

    /// Whether the check is over: nothing was announced, a notification was clicked, or the click window closed.
    private final class Progress {
        var isFinished = false
    }

    static func run(loop: EventLoop) -> Int32 {
        guard !crucible_app_is_running() else { return 0 }
        guard let connection = ServerBootstrap.connection(), !DemoMode.shared.isActive, let notifications = DesktopNotifications(loop: loop) else { return 0 }
        Artwork.pipeline = PlexArtworkPipeline(baseURL: connection.serverURI)
        let progress = Progress()
        notifications.onOpen = { link, token in
            open(link, token: token)
            progress.isFinished = true
        }
        let watcher = LibraryNewsWatcher(notifications: notifications)
        Task { @MainActor in
            await watcher.check(post: true)
            guard notifications.hasPosted else {
                progress.isFinished = true
                return
            }
            try? await Task.sleep(for: .seconds(clickWindow))
            progress.isFinished = true
        }
        loop.run { progress.isFinished }
        notifications.close()
        return 0
    }

    /// Hands the link to Crucible when it started meanwhile, or starts it on the link.
    private static func open(_ link: URL, token: String?) {
        let uris = [link.absoluteString]
        let forwarded = uris.withCStringArray { crucible_app_forward($0.baseAddress, Int32($0.count), token) }
        guard !forwarded else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        process.arguments = [link.absoluteString]
        var environment = ProcessInfo.processInfo.environment
        if let token { environment["XDG_ACTIVATION_TOKEN"] = token }
        process.environment = environment
        try? process.run()
    }
}

private extension Array where Element == String {
    /// The strings as NUL-terminated pointers that live for the call.
    func withCStringArray<Result>(_ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> Result) -> Result {
        let copies = map { strdup($0) }
        defer { copies.forEach { free($0) } }
        return copies.map { UnsafePointer($0) }.withUnsafeBufferPointer(body)
    }
}
