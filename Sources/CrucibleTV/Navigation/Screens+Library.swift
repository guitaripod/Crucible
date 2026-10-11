import CrucibleCore
import UIKit

extension TVScreens {
    static func library(_ env: TVAppEnvironment, section: PlexDirectory) -> UIViewController {
        TVPlaceholderViewController(name: section.title ?? "Library")
    }

    static func more(_ env: TVAppEnvironment) -> UIViewController {
        TVPlaceholderViewController(name: "More")
    }
}
