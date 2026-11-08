import Foundation

/// The item a playback is of, as an integration needs it to say what is being watched.
package struct PlaybackSubject: Sendable {
    package let ratingKey: String
    package let mediaType: String
    package let showRatingKey: String?
    package let title: String
    package let showTitle: String?
    package let seasonNumber: Int?
    package let episodeNumber: Int?
    package let durationSecs: Double
    package let server: String
    package let api: APIClient

    package init(
        ratingKey: String,
        mediaType: String,
        showRatingKey: String?,
        title: String,
        showTitle: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        durationSecs: Double,
        server: String,
        api: APIClient
    ) {
        self.ratingKey = ratingKey
        self.mediaType = mediaType
        self.showRatingKey = showRatingKey
        self.title = title
        self.showTitle = showTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.durationSecs = durationSecs
        self.server = server
        self.api = api
    }

    package var isEpisode: Bool { mediaType == "episode" }

    /// How far into the item `position` is, from 0 to 100.
    package func progress(at position: Double) -> Double {
        guard durationSecs > 0 else { return 0 }
        return min(100, max(0, position / durationSecs * 100))
    }
}

/// What happened to a playback, in the order it happened.
package enum PlaybackChange: Equatable, Sendable {
    case playing(position: Double)
    case paused(position: Double)
    /// The run ended at `position`; `finished` follows the app's own watched rule (the credits or the percentage).
    case stopped(position: Double, finished: Bool, at: Date)
}

/// Follows one playback for an integration.
@MainActor
package protocol PlaybackWatching: AnyObject {
    func playback(_ change: PlaybackChange)
}

/// A service Crucible can work with once the viewer connects it. Nothing of a plugin runs until it is active: the app
/// asks every plugin before each playback, each manual change and each sign-out, and an inactive one answers nothing.
@MainActor
package protocol IntegrationPlugin: AnyObject {
    var id: String { get }
    var isActive: Bool { get }
    func makePlaybackWatcher(for subject: PlaybackSubject) -> PlaybackWatching?
    func watchedChanged(_ ratingKey: String, watched: Bool, api: APIClient, server: String)
    func ratingChanged(_ ratingKey: String, rating: UserRating?, api: APIClient, server: String)
    /// The app connected to `server`: load what belongs to the viewer watching now and send what is still owed.
    func launched(api: APIClient, server: String) async
    /// The Plex account signed out: forget everything of every profile on this device.
    func signedOut() async
}

/// The plugins this build carries, and the seams the app calls them through.
@MainActor
package enum Integrations {
    package static var plugins: [IntegrationPlugin] = [TraktPlugin.shared, SeerrPlugin.shared]

    /// One watcher per active plugin that follows `subject`.
    package static func playbackWatchers(for subject: PlaybackSubject) -> [PlaybackWatching] {
        plugins.filter(\.isActive).compactMap { $0.makePlaybackWatcher(for: subject) }
    }

    /// The viewer marked `ratingKey` (a movie, episode, season or show) watched or unwatched on the server.
    package static func watchedChanged(_ ratingKey: String, watched: Bool, api: APIClient) {
        guard let server = ServerBootstrap.savedMachineIdentifier else { return }
        for plugin in plugins where plugin.isActive { plugin.watchedChanged(ratingKey, watched: watched, api: api, server: server) }
    }

    /// The viewer rated `ratingKey`, or cleared its rating with nil.
    package static func ratingChanged(_ ratingKey: String, rating: UserRating?, api: APIClient) {
        guard let server = ServerBootstrap.savedMachineIdentifier else { return }
        for plugin in plugins where plugin.isActive { plugin.ratingChanged(ratingKey, rating: rating, api: api, server: server) }
    }

    package static func launched(api: APIClient, server: String) async {
        for plugin in plugins { await plugin.launched(api: api, server: server) }
    }

    package static func signedOut() async {
        for plugin in plugins { await plugin.signedOut() }
    }

    /// The line under Integrations on the first Settings screen: the one integration that is on with its detail, the names
    /// of several, or Off.
    package static var summary: String {
        let details = [TraktAccount.shared.isConnected || TraktAccount.shared.status == .needsReconnect ? TraktAccount.shared.summary : nil, SeerrAccount.shared.summary].compactMap { $0 }
        switch details.count {
        case 0: return TraktAccount.shared.summary
        case 1: return details[0]
        default: return [TraktCopy.name, SeerrCopy.name].joined(separator: ", ")
        }
    }
}
