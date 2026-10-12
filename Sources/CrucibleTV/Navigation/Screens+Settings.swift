import UIKit

extension TVScreens {
    static func settings(_ env: TVAppEnvironment, page: TVSettingsPage) -> UIViewController {
        switch page {
        case .playback: TVPlaybackSettingsViewController()
        case .libraries: TVLibrariesSettingsViewController(api: env.api)
        case .server: TVServerSettingsViewController(env: env)
        case .diagnostics: TVDiagnosticsViewController()
        case .about: TVAboutViewController()
        case .pro: TVProViewController()
        }
    }
}
