import CrucibleCore
@preconcurrency import UIKit

/// What a cast member has done in the viewer's libraries.
@MainActor
enum PersonScreens {
    static func filmography(api: APIClient, person: PlexRole) -> MediaGridViewController {
        let grid = MediaGridViewController(
            title: person.tag ?? "",
            empty: .init(
                symbol: "person.crop.rectangle.stack",
                title: String(localized: "Nothing in Your Libraries"),
                text: String(localized: "None of this person\u{2019}s titles are on your server.")
            )
        ) {
            try await PersonFilmography.titles(of: person, api: api)
        }
        MediaGridActions.install(on: grid, api: api)
        return grid
    }
}
