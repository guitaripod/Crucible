import AVFoundation
import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

public final class TVAppDelegate: UIResponder, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CrucibleLog.configure()
        CrucibleLog.logUncaughtExceptions()
        MidgarLog.notice("App launched — \(AppInfo.versionSummary) (log: \(MidgarLog.logFileURLs.first?.path ?? "none"))", category: .lifecycle)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #if DEBUG
        TVDebugSession.bootstrapIfRequested()
        #endif
        ServerRouteMonitor.shared.start()
        Self.followAppActivity()
        return true
    }

    /// The route monitor looks again when the app comes back to the front, and rests while it is away.
    private static func followAppActivity() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ServerRouteMonitor.shared.appBecameActive() }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ServerRouteMonitor.shared.appResignedActive() }
        }
    }

    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TVSceneDelegate.self
        return configuration
    }

    public func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        MidgarLog.notice("Memory warning: purging the in-memory image cache", category: .lifecycle)
        Task { await ImageLoader.shared.purgeMemoryCache() }
    }
}
