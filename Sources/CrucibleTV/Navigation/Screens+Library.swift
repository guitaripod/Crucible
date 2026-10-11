import CrucibleCore
import UIKit

extension TVScreens {
    static func library(_ env: TVAppEnvironment, section: PlexDirectory) -> UIViewController {
        let kind = LibraryGridKind(sectionType: section.type) ?? .movie
        let library = LibrarySection(id: section.key ?? "", title: section.title ?? kind.defaultTitle, kind: kind)
        return TVLibraryViewController(env: env, section: library)
    }

    static func more(_ env: TVAppEnvironment) -> UIViewController {
        TVMoreViewController(env: env)
    }
}
