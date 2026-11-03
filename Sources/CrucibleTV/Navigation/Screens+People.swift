import CrucibleCore
import UIKit

extension TVScreens {
    static func filmography(_ env: TVAppEnvironment, person: PlexRole) -> UIViewController {
        let grid = TVMediaGridViewController(
            title: person.tag ?? "",
            empty: .init(
                symbol: "person.crop.rectangle.stack",
                title: String(localized: "Nothing in Your Libraries"),
                message: String(localized: "None of this person\u{2019}s titles are on your server.")
            ),
            card: titleCard,
            load: { try await PersonFilmography.titles(of: person, api: env.api) }
        )
        installTitleActions(on: grid, env: env)
        return grid
    }
}
