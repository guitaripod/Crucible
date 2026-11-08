import Foundation

/// Seerr as an integration: requests for titles the server does not have, on the viewer's own Seerr. It follows no
/// playback and sends no changes; it signs in again at launch and forgets every profile's connection at sign-out.
@MainActor
package final class SeerrPlugin: IntegrationPlugin {
    package static let shared = SeerrPlugin()

    package let id = "seerr"
    private let account: SeerrAccount

    package init(account: SeerrAccount = .shared) {
        self.account = account
    }

    package var isActive: Bool { account.isConnected }

    package func makePlaybackWatcher(for subject: PlaybackSubject) -> PlaybackWatching? { nil }

    package func watchedChanged(_ ratingKey: String, watched: Bool, api: APIClient, server: String) {}

    package func ratingChanged(_ ratingKey: String, rating: UserRating?, api: APIClient, server: String) {}

    package func launched(api: APIClient, server: String) async {
        await account.load()
    }

    package func signedOut() async {
        await account.forgetEveryProfile()
    }
}
