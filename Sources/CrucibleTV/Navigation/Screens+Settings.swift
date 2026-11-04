import UIKit

extension TVScreens {
    static func settings(_ env: TVAppEnvironment, page: TVSettingsPage) -> UIViewController {
        switch page {
        case .playback: TVSettingsCategoryViewController(env: env, category: .playback)
        case .remote: TVSettingsCategoryViewController(env: env, category: .controls)
        case .homeRows: TVHomeRowsViewController()
        case .privacy: TVSettingsCategoryViewController(env: env, category: .privacy)
        case .libraries: TVLibrariesSettingsViewController(api: env.api)
        case .server: TVServerSettingsViewController(env: env)
        case .diagnostics: TVDiagnosticsViewController()
        case .about: TVAboutViewController()
        case .pro: TVProViewController()
        }
    }
}
