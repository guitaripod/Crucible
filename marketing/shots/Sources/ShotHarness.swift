import UIKit
@testable import Crucible

/// Seeds the app with a mock Plex connection and drives it through the screens used for marketing
/// captures. Each `capture(_:)` raises a `<name>.ready` file and waits for the outer script to take
/// the simulator screenshot and answer with `<name>.ack`.
@MainActor
enum ShotHarness {
    static var signalDirectory: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_SIGNAL_DIR"] ?? "/tmp/crucible-shots"
    }

    static func bootstrap() {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(string: environment["CRUCIBLE_MOCK"] ?? "http://127.0.0.1:32400")!
        ServerBootstrap.clear()
        ServerBootstrap.saveToken("mock-token")
        ServerBootstrap.saveServer(uri: base, name: "Marcus-PC", machineIdentifier: "9c1f0e2a7b3d4e5f8a6b1c2d3e4f5a6b")
        UserDefaults.standard.set("Marcus", forKey: "plex_account_name")
        if environment["CRUCIBLE_LIGHT"] == "1" {
            Preferences.appearance = .light
        } else {
            Preferences.appearance = .dark
        }

        DownloadSeeder.seed(base: base, specs: [
            .init(ratingKey: "4009", state: .completed, progress: 1, watched: 1.0, gigabytes: 1.3, ageDays: 6),
            .init(ratingKey: "4010", state: .completed, progress: 1, watched: 1.0, gigabytes: 1.2, ageDays: 6),
            .init(ratingKey: "4011", state: .completed, progress: 1, watched: 0, gigabytes: 1.4, ageDays: 5),
            .init(ratingKey: "4012", state: .completed, progress: 1, watched: 0.58, gigabytes: 1.3, ageDays: 5),
            .init(ratingKey: "4036", state: .completed, progress: 1, watched: 0, gigabytes: 1.1, ageDays: 3),
            .init(ratingKey: "4037", state: .completed, progress: 1, watched: 0, gigabytes: 1.2, ageDays: 3),
            .init(ratingKey: "1002", state: .completed, progress: 1, watched: 0.42, gigabytes: 6.4, ageDays: 2),
            .init(ratingKey: "1001", state: .completed, progress: 1, watched: 1.0, gigabytes: 6.8, ageDays: 9),
            .init(ratingKey: "4013", state: .paused, progress: 0.64, watched: 0, gigabytes: 1.3, ageDays: 0.1),
        ])

        if environment["CRUCIBLE_PROBE"] == "1" {
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LayoutProbe.run() }
            }
            return
        }

        var started = false
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !started else { return }
                started = true
                Task { await ShotScript.run() }
            }
        }
    }

    static func capture(_ name: String) async {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(atPath: signalDirectory, withIntermediateDirectories: true)
        let ready = "\(signalDirectory)/\(name).ready"
        let ack = "\(signalDirectory)/\(name).ack"
        try? fileManager.removeItem(atPath: ack)
        fileManager.createFile(atPath: ready, contents: nil)
        for _ in 0..<300 {
            if fileManager.fileExists(atPath: ack) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static var rootWindow: UIWindow? {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first { return window }
        }
        return nil
    }

    static func waitForTabBar() async -> TabBarController? {
        for _ in 0..<300 {
            if let tabBar = rootWindow?.rootViewController as? TabBarController { return tabBar }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
