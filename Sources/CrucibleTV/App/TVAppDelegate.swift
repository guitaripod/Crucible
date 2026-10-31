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
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            MidgarLog.fault("Uncaught exception: \(exception.name.rawValue) - \(exception.reason ?? "no reason")\n\(stack)", category: .lifecycle)
            MidgarLog.flush()
        }
        MidgarLog.notice("App launched — \(AppInfo.versionSummary) (log: \(MidgarLog.logFileURLs.first?.path ?? "none"))", category: .lifecycle)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #if DEBUG
        TVDebugSession.bootstrapIfRequested()
        #endif
        return true
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
