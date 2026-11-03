import AVFoundation
import CrucibleCore
import MidgarCore
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CrucibleLog.configure()
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            MidgarLog.fault("Uncaught exception: \(exception.name.rawValue) - \(exception.reason ?? "no reason")\n\(stack)", category: .lifecycle)
            MidgarLog.flush()
        }
        MidgarLog.notice("App launched (log: \(MidgarLog.logFileURLs.first?.path ?? "none"))", category: .lifecycle)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        application.beginReceivingRemoteControlEvents()
        #if DEBUG
        PhoneDebugSession.bootstrapIfRequested()
        #endif
        ProAccess.shared.configureForLaunch(store: nil)
        PaywallPresenter.install()
        DemoCoordinator.shared.install()
        DownloadManager.shared.bootstrap()
        NotificationCoordinator.shared.install()
        PreferenceSetting.didChange = { setting in Self.preferenceChanged(setting) }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if #available(iOS 26.0, *) {
            installMainMenu()
        }
        return true
    }

    /// Carries a change made in Settings to the part of the app that owns it.
    private static func preferenceChanged(_ setting: PreferenceSetting) {
        switch setting {
        case .appearance:
            for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.25
                UIView.transition(with: window, duration: duration, options: .transitionCrossDissolve) {
                    AppearanceController.apply(to: window)
                }
            }
        case .downloadOverCellular:
            DownloadManager.shared.cellularPreferenceChanged()
        case .ratingReminderTiming, .quietHours:
            NotificationCoordinator.shared.preferencesChanged()
        default:
            if setting.notificationKind != nil { NotificationCoordinator.shared.preferencesChanged() }
        }
    }

    /// The iPad menu bar: a New Window item, no document, print, find or text formatting groups, and Crucible's own menus.
    @available(iOS 26.0, *)
    private func installMainMenu() {
        let configuration = UIMainMenuSystem.Configuration()
        configuration.newScenePreference = .included
        configuration.documentPreference = .removed
        configuration.printingPreference = .removed
        configuration.findingPreference = .removed
        configuration.inspectorPreference = .removed
        configuration.textFormattingPreference = .removed
        UIMainMenuSystem.shared.setBuildConfiguration(configuration) { builder in
            AppMenu.build(builder)
        }
    }

    /// Before iPadOS 26 the same commands fill the shortcut overlay shown while Command is held.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        if #available(iOS 26.0, *) { return }
        AppMenu.buildLegacy(builder)
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let tap = NotificationTap(response)
        await NotificationCoordinator.shared.handle(tap)
    }
}
