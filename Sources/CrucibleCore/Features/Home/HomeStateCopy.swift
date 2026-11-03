import Foundation

/// Title and explanation for a Home state that has no content to show.
package struct HomeStateCopy: Equatable, Sendable {
    package let title: String
    package let message: String

    /// Nothing to show: the viewer turned the rows off, the chosen libraries have nothing, or the server has no media.
    package static func empty(librariesAreFiltered: Bool, rowsAreHidden: Bool = false) -> HomeStateCopy {
        if rowsAreHidden {
            return HomeStateCopy(
                title: String(localized: "Home Rows Are Off", comment: "Title of the empty Home screen when the viewer turned its rows off"),
                message: String(localized: "Turn rows back on in Settings › Home.", comment: "Message on the empty Home screen when the viewer turned its rows off")
            )
        }
        if librariesAreFiltered {
            return HomeStateCopy(
                title: String(localized: "Nothing From These Libraries"),
                message: String(localized: "Home is limited to the libraries you chose in Settings.")
            )
        }
        return HomeStateCopy(title: String(localized: "Nothing Here Yet"), message: String(localized: "Add media to your Plex libraries to see it here."))
    }

    package static func loadFailed(_ error: Error) -> HomeStateCopy {
        HomeStateCopy(title: String(localized: "Couldn't Reach Server"), message: ConnectionError.message(for: error))
    }
}
