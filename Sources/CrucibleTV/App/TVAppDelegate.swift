import AVFoundation
import CrucibleCore
import CrucibleDesign
import UIKit

public final class TVAppDelegate: UIResponder, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            AppLogger.fault("Uncaught exception: \(exception.name.rawValue) - \(exception.reason ?? "no reason")\n\(stack)", .lifecycle, sync: true)
        }
        AppLogger.notice("App launched (log: \(LogFileWriter.shared.currentPath))", .lifecycle)
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
        AppLogger.notice("Memory warning: purging the in-memory image cache", .lifecycle)
        Task { await ImageLoader.shared.purgeMemoryCache() }
    }
}
