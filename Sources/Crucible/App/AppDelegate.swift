import AVFoundation
import CrucibleCore
import UIKit
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
        #if DEBUG
        PhoneDebugSession.bootstrapIfRequested()
        #endif
        ProAccess.shared.configureForLaunch(store: nil)
        PaywallPresenter.install()
        DemoCoordinator.shared.install()
        DownloadManager.shared.bootstrap()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if #available(iOS 26.0, *) {
            installMainMenu()
        }
        return true
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
        let userInfo = response.notification.request.content.userInfo
        guard let ratingKey = userInfo["ratingKey"] as? String,
              let mediaType = userInfo["mediaType"] as? String else { return }
        await MainActor.run {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let tabBars = scenes.sorted { $0.activationState.rawValue < $1.activationState.rawValue }
                .compactMap { ($0.keyWindow ?? $0.windows.first)?.rootViewController as? TabBarController }
            tabBars.first?.openMedia(ratingKey: ratingKey, mediaType: mediaType)
        }
    }
}
