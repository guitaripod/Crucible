import UIKit
import AVFoundation

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NSSetUncaughtExceptionHandler { exception in
            NSLog("CRUCIBLE EXCEPTION: %@ - %@", exception.name.rawValue, exception.reason ?? "no reason")
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        application.beginReceivingRemoteControlEvents()
        return true
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
