import Foundation

/// Title and explanation for a Home state that has no content to show.
package struct HomeStateCopy: Equatable, Sendable {
    package let title: String
    package let message: String

    /// Nothing to show: either the server has no media, or the chosen libraries have none.
    package static func empty(librariesAreFiltered: Bool) -> HomeStateCopy {
        if librariesAreFiltered {
            return HomeStateCopy(
                title: "Nothing From These Libraries",
                message: "Home is limited to the libraries you chose in Settings."
            )
        }
        return HomeStateCopy(title: "Nothing Here Yet", message: "Add media to your Plex libraries to see it here.")
    }

    package static func loadFailed(_ error: Error) -> HomeStateCopy {
        HomeStateCopy(title: "Couldn't Reach Server", message: ConnectionError.message(for: error))
    }
}
