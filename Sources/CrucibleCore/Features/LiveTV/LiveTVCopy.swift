import Foundation

/// Every word Live TV shows, shared by the iPhone, iPad, Apple TV and Linux screens.
package enum LiveTVCopy {
    package static let title = String(localized: "Live TV", comment: "Name of the Live TV section, tab and screen")
    package static let guide = String(localized: "Guide", comment: "Title of the TV guide grid")
    package static let channels = String(localized: "Channels", comment: "Title of the list of live TV channels")
    package static let allChannels = String(localized: "All Channels", comment: "Live TV filter showing every channel")
    package static let favorites = String(localized: "Favorites", comment: "Live TV filter showing the viewer's favourite channels")
    package static let recent = String(localized: "Recent", comment: "Live TV filter showing the channels watched last")
    package static let plexFreeTitle = String(localized: "Plex Channels", comment: "Name of Plex's free live channels as a Live TV source")
    package static let yourServer = String(localized: "Your Server", comment: "Fallback name of the viewer's Plex server as a Live TV source")
    package static let nowPlaying = String(localized: "On Now", comment: "Label before the airing a channel is showing now")
    package static let upNext = String(localized: "Up Next", comment: "Label before the airing that follows on a channel")
    package static let noGuide = String(localized: "No guide information", comment: "Shown in the TV guide for a channel without listings")
    package static let loadingGuide = String(localized: "Loading guide…", comment: "Shown in the TV guide while a channel's listings load")
    package static let watch = String(localized: "Watch", comment: "Button that plays a live TV channel")
    package static let watchLive = String(localized: "Watch Live", comment: "Button that plays the channel an airing is on")
    package static let addFavorite = String(localized: "Add to Favorites", comment: "Menu item that marks a live TV channel as a favourite")
    package static let removeFavorite = String(localized: "Remove from Favorites", comment: "Menu item that unmarks a favourite live TV channel")
    package static let channelUp = String(localized: "Channel Up", comment: "Command that switches to the next live TV channel")
    package static let channelDown = String(localized: "Channel Down", comment: "Command that switches to the previous live TV channel")
    package static let previousChannel = String(localized: "Previous Channel", comment: "Command that returns to the live TV channel watched before")
    package static let live = String(localized: "LIVE", comment: "Badge on a live TV picture or airing that is on now; keep it short and uppercase where the script has case")
    package static let new = String(localized: "NEW", comment: "Badge on a TV airing that is a new episode; keep it short")
    package static let tryAgain = String(localized: "Try Again", comment: "Button that reloads live TV after a failure")
    package static let filter = String(localized: "Filter", comment: "Button that picks which live TV channels the guide shows")
    package static let categories = String(localized: "Categories", comment: "Button that picks a category (group) of live TV channels")
    package static let jumpToNow = String(localized: "Now", comment: "Button that scrolls the TV guide back to the current time")

    package static let emptyTitle = String(localized: "No Channels Yet", comment: "Title shown in Live TV when no source has any channels")
    package static let emptyText = String(localized: "Add a channel playlist (M3U) from your TV provider, connect a tuner to your Plex server, or turn on Plex’s free channels in Settings.",
                                          comment: "Message shown in Live TV when no source has any channels")
    package static let failedTitle = String(localized: "Live TV Didn’t Load", comment: "Title shown when every live TV source failed")
    package static let noFavoritesText = String(localized: "Mark channels as favorites to keep them here.", comment: "Shown under the Favorites filter when it is empty")

    package static func failure(_ error: Error, source: String) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return String(localized: "\(source): \(reason)", comment: "A live TV source that failed and why, e.g. 'My IPTV: The playlist's server answered 403.'")
    }

    package static func channelCount(_ count: Int) -> String {
        String(localized: "\(count) channels", comment: "Number of live TV channels in a source or group")
    }

    // MARK: Beta

    package static let beta = String(localized: "BETA", comment: "Tag beside the Live TV title marking the feature as a beta; keep it short and uppercase where the script has case")
    package static let betaTitle = String(localized: "Live TV Is in Beta", comment: "Title of the note the Beta tag beside Live TV opens")
    package static let betaIntro = String(localized: "Live TV is new in Crucible and still growing. Here’s what it does today.",
                                          comment: "First line of the note the Beta tag beside Live TV opens")
    /// What Live TV covers, each with the symbol it is drawn beside.
    package static let betaPoints: [(symbol: String, text: String)] = [
        ("tv", String(localized: "Plex’s free channels and their guide, on every Plex account.", comment: "Live TV beta note: what Plex's free channels give")),
        ("antenna.radiowaves.left.and.right", String(localized: "Channels from a tuner on your Plex server, with recordings (recording needs Plex Pass on the server).",
                                                     comment: "Live TV beta note: tuner channels and recording")),
        ("list.bullet", String(localized: "Channel playlists (M3U) with their XMLTV guide, from a TV provider you subscribe to.",
                               comment: "Live TV beta note: the viewer's own playlists")),
    ]
    package static let betaFooter = String(localized: "Some streams take a moment to start, and channels whose provider publishes no guide show none. Crucible provides no channels of its own. Tell me what works and what doesn’t: your feedback decides what comes next.",
                                           comment: "Last paragraph of the Live TV beta note; written in the developer's first person singular")

    /// The whole note as one text, for a screen reader or a platform that shows it as a plain message.
    package static var betaBody: String {
        ([betaIntro] + betaPoints.map { "• \($0.text)" } + [betaFooter]).joined(separator: "\n\n")
    }

    package static let betaFeedback = String(localized: "Send Feedback", comment: "Button in the Live TV beta note that opens an email to the developer")
    package static let betaDismiss = String(localized: "Got It", comment: "Button that closes the Live TV beta note")
    package static let feedbackAddress = "marcus@midgarcorp.cc"
    package static let feedbackSubject = "Crucible Live TV beta"

    package static var feedbackURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackAddress
        components.queryItems = [URLQueryItem(name: "subject", value: feedbackSubject)]
        return components.url
    }

    // MARK: Settings

    package static let settingsSummary = String(localized: "Plex’s free channels, a tuner on your server and your own channel playlists.", comment: "Settings: what the Live TV page holds")
    package static let showDestination = String(localized: "Show Live TV", comment: "Setting that shows or hides the Live TV tab")
    package static let showDestinationFooter = String(localized: "Live TV gets its own tab with the guide.", comment: "Footer under the setting that shows the Live TV tab")

    // MARK: Playlists

    package static let playlists = String(localized: "Channel Playlists", comment: "Settings section listing the viewer's M3U channel playlists")
    package static let addPlaylist = String(localized: "Add Playlist", comment: "Button that adds an M3U channel playlist")
    package static let editPlaylist = String(localized: "Edit Playlist", comment: "Title of the screen that changes an M3U channel playlist")
    package static let removePlaylist = String(localized: "Remove Playlist", comment: "Button that removes an M3U channel playlist")
    package static let removePlaylistQuestion = String(localized: "Remove This Playlist?", comment: "Title of the confirmation before removing a channel playlist")
    package static let removePlaylistText = String(localized: "Its channels leave the guide. You can add it again with its address.", comment: "Message of the confirmation before removing a channel playlist")
    package static let playlistName = String(localized: "Name", comment: "Field label for a channel playlist's name")
    package static let playlistAddress = String(localized: "Playlist Address (M3U)", comment: "Field label for a channel playlist's M3U address")
    package static let guideAddress = String(localized: "Guide Address (XMLTV, Optional)", comment: "Field label for a channel playlist's XMLTV guide address")
    package static let userAgent = String(localized: "User Agent (Optional)", comment: "Field label for the user agent a channel playlist's streams are asked with")
    package static let playlistNote = String(localized: "Use a playlist from a TV provider you subscribe to. The addresses usually carry your account, so Crucible keeps them in the device’s secure storage and never shares them.",
                                             comment: "Note under the fields for adding a channel playlist")
    package static let invalidAddress = String(localized: "Enter a web address starting with http:// or https://.", comment: "Error when a channel playlist address is not a web address")
    package static let checkingPlaylist = String(localized: "Checking the playlist…", comment: "Shown while a new channel playlist is loaded to check it")
    package static let showPlexChannels = String(localized: "Plex’s Free Channels", comment: "Setting that shows or hides Plex's free live channels in the guide")
    package static let showPlexChannelsFooter = String(localized: "Hundreds of free channels from Plex, with ads, available on every Plex account.", comment: "Footer under the setting for Plex's free live channels")
    package static let refreshPlaylists = String(localized: "Refresh Channels", comment: "Button that loads every channel playlist and guide again")

    package static func playlistAdded(_ name: String, channels: Int) -> String {
        String(localized: "\(name) added with \(channels) channels.", comment: "Confirmation after a channel playlist was added, e.g. 'My TV added with 120 channels.'")
    }

    package static func importQuestion(_ name: String) -> String {
        String(localized: "Add the Playlist “\(name)”?", comment: "Title of the confirmation when a link asks to add a channel playlist")
    }

    package static let importText = String(localized: "A link asked Crucible to add this channel playlist to Live TV. Only add playlists you trust.",
                                            comment: "Message of the confirmation when a link asks to add a channel playlist")
    package static let add = String(localized: "Add", comment: "Button that confirms adding a channel playlist")

    // MARK: Recording

    package static let recordings = String(localized: "Recordings", comment: "Title of the Live TV screen listing scheduled recordings and rules")
    package static let record = String(localized: "Record", comment: "Button that schedules a recording of an airing")
    package static let recordEpisode = String(localized: "Record This Episode", comment: "Option that records one airing")
    package static let recordSeries = String(localized: "Record Series", comment: "Option that records every episode of a show")
    package static let scheduled = String(localized: "Scheduled", comment: "Section of upcoming recordings")
    package static let recordingNow = String(localized: "Recording", comment: "Status of a recording in progress, and its section")
    package static let rules = String(localized: "Recording Rules", comment: "Section of standing recording rules")
    package static let cancelRecording = String(localized: "Cancel Recording", comment: "Button that cancels a scheduled recording")
    package static let deleteRule = String(localized: "Delete Rule", comment: "Button that deletes a recording rule")
    package static let deleteRuleQuestion = String(localized: "Delete This Rule?", comment: "Title of the confirmation before deleting a recording rule")
    package static let deleteRuleText = String(localized: "Upcoming recordings from it are cancelled. What it already recorded stays in your library.", comment: "Message of the confirmation before deleting a recording rule")
    package static let noRecordings = String(localized: "Nothing Scheduled", comment: "Title shown when no recordings are scheduled")
    package static let noRecordingsText = String(localized: "Record an airing from the guide and it shows up here.", comment: "Message shown when no recordings are scheduled")
    package static let recordingScheduled = String(localized: "Recording scheduled", comment: "Confirmation after a recording was scheduled")
    package static let recordingFailed = String(localized: "Couldn’t schedule the recording.", comment: "Error when a recording could not be scheduled")
    package static let recordingNeedsPass = String(localized: "Recording needs Plex Pass on the server owner’s account.", comment: "Error when the Plex server refused to record")
    package static let recordingOptions = String(localized: "Recording Options", comment: "Title of the sheet with a recording's settings")
    package static let failedStatus = String(localized: "Failed", comment: "Status of a recording that failed")

    package static func savesTo(_ library: String) -> String {
        String(localized: "Saves to \(library)", comment: "Where a recording is saved, e.g. 'Saves to TV Shows'")
    }

    package static func recordingError(_ error: Error) -> String {
        if case APIError.httpError(let status, _) = error, status == 403 { return recordingNeedsPass }
        if case APIError.unauthorized = error { return recordingNeedsPass }
        return recordingFailed
    }
}
