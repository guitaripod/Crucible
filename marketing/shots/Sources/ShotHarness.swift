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
