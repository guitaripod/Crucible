import UIKit
import AVFoundation
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            AppLogger.fault("Uncaught exception: \(exception.name.rawValue) - \(exception.reason ?? "no reason")\n\(stack)", .lifecycle, sync: true)
        }
        AppLogger.notice("App launched (log: \(LogFileWriter.shared.currentPath))", .lifecycle)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        application.beginReceivingRemoteControlEvents()
        DownloadManager.shared.bootstrap()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
