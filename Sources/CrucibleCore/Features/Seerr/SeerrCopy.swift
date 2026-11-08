import Foundation

/// The words of the Seerr integration, shared by iPhone, iPad and Apple TV.
package enum SeerrCopy {
    package static let name = "Seerr"
    package static let tagline = String(localized: "Ask for what isn't on your server", comment: "Subtitle of the Seerr integration")
    package static let worksWith = String(localized: "Works with Seerr, Overseerr and Jellyseerr set up for Plex.", comment: "Which request apps the Seerr integration supports")

    package static let pitchRequest = String(localized: "Request a movie or show from your watchlist, or the seasons a show is missing", comment: "First line of the Seerr pitch")
    package static let pitchState = String(localized: "See it go from requested to downloading to ready to play", comment: "Second line of the Seerr pitch")
    package static let pitchArrival = String(localized: "Requests join your Plex watchlist, so Watchlist Arrivals tells you when they land", comment: "Third line of the Seerr pitch")
    package static let privacy = String(localized: "Seerr runs on your own server. Crucible talks to it directly and signs in with your Plex account; nothing goes anywhere else.", comment: "Privacy note in Seerr settings")

    package static let searching = String(localized: "Looking for Seerr on your network…", comment: "Status while Crucible looks for Seerr next to the Plex server")
    package static let found = String(localized: "Found Seerr", comment: "Section title when Crucible found Seerr on the network")
    package static let notFound = String(localized: "Crucible didn't find Seerr next to your Plex server. Enter its address.", comment: "Status when discovery found nothing")
    package static let connect = String(localized: "Connect with Plex", comment: "Button that signs in to Seerr with the viewer's Plex account")
    package static let enterAddress = String(localized: "Enter Address", comment: "Button that lets the viewer type the Seerr address")
    package static let addressTitle = String(localized: "Seerr Address", comment: "Title of the prompt for the Seerr address")
    package static let addressMessage = String(localized: "The address you open Seerr at, such as 192.168.1.20:5055 or requests.example.com.", comment: "Message of the prompt for the Seerr address")
    package static let addressPlaceholder = String(localized: "Address", comment: "Placeholder of the Seerr address field")
    package static let useAPIKey = String(localized: "Use an API Key Instead", comment: "Button for connecting to Seerr with an API key")
    package static let apiKeyTitle = String(localized: "Seerr API Key", comment: "Title of the prompt for the Seerr API key")
    package static let apiKeyMessage = String(localized: "Find it in Seerr under Settings › General. Requests made with it are made as Seerr's administrator.", comment: "Message of the prompt for the Seerr API key")
    package static let apiKeyPlaceholder = String(localized: "API Key", comment: "Placeholder of the Seerr API key field")
    package static let connecting = String(localized: "Connecting…", comment: "Status while Crucible signs in to Seerr")
    package static let requesting = String(localized: "Requesting…", comment: "Request button while the request is being sent to Seerr")
    package static let connectFailed = String(localized: "Couldn't Connect", comment: "Title of the alert when connecting to Seerr failed")
    package static let disconnect = String(localized: "Disconnect", comment: "Button that disconnects Seerr")
    package static let disconnectTitle = String(localized: "Disconnect Seerr?", comment: "Confirmation title for disconnecting Seerr")
    package static let disconnectMessage = String(localized: "Crucible signs out of Seerr on this device. Your requests stay in Seerr.", comment: "Confirmation message for disconnecting Seerr")
    package static let reconnect = String(localized: "Connect Again", comment: "Button that reconnects Seerr after it signed Crucible out")
    package static let needsReconnect = String(localized: "Seerr signed Crucible out. Connect again to keep requesting.", comment: "Shown when Seerr refused the session")
    package static let restricted = String(localized: "This Plex Home profile can't request titles. The account owner can, on their own profile.", comment: "Shown on a restricted Home profile instead of Connect")
    package static let signedInAs = String(localized: "Signed In As", comment: "Seerr settings row naming the Seerr user")
    package static let apiKeyAccount = String(localized: "Seerr Administrator (API key)", comment: "Seerr settings value when connected with an API key")
    package static let canRequest = String(localized: "Can Request", comment: "Seerr settings row saying what the viewer may request")
    package static let autoApproved = String(localized: "Approved automatically", comment: "Seerr settings value: the viewer's requests need no approval")
    package static let needsApproval = String(localized: "Needs approval", comment: "Seerr settings value: the viewer's requests wait for approval")
    package static let cannotRequest = String(localized: "Not allowed", comment: "Seerr settings value: the viewer may not request")

    package static let request = String(localized: "Request", comment: "Button that asks Seerr for a title")
    package static let requestMore = String(localized: "Request More Seasons", comment: "Menu item that asks Seerr for seasons a show is missing")
    package static let requestTitle = String(localized: "Request", comment: "Title of the Request sheet")
    package static let chooseSeasons = String(localized: "Seasons", comment: "Section title for picking seasons to request")
    package static let allMissing = String(localized: "All Missing Seasons", comment: "Choice that requests every season the server lacks")
    package static let onlyAllSeasons = String(localized: "This Seerr takes whole shows only, so every missing season is requested.", comment: "Note when Seerr does not allow requesting single seasons")
    package static let withdraw = String(localized: "Withdraw Request", comment: "Button that withdraws the viewer's pending request")
    package static let play = String(localized: "Play", comment: "Button that opens a requested title once it arrived")
    package static let alsoWatchlist = String(localized: "Added to your Watchlist, so you'll hear when it arrives.", comment: "Note after requesting: the title was saved to the Plex watchlist")
    package static let requested = String(localized: "Requested", comment: "Toast after a request was sent")
    package static let seeRequests = String(localized: "See Your Requests", comment: "Button after requesting that opens the requests screen")

    /// The Request button when only some seasons are chosen, e.g. Request 2 Seasons.
    package static func requestSeasons(_ count: Int) -> String {
        String(localized: "Request \(count) Seasons", comment: "Button that requests the chosen seasons, e.g. Request 2 Seasons")
    }
    package static let notConnectedTitle = String(localized: "Not on Your Server", comment: "Title when a title is not on the server and Seerr is not connected")
    package static let notConnectedMessage = String(localized: "Connect Seerr, Overseerr or Jellyseerr in Settings › Integrations to request it from here.", comment: "Message when a title is not on the server and Seerr is not connected")
    package static let setUp = String(localized: "Set Up Requests", comment: "Button that opens the Seerr settings")
    package static let notIdentified = String(localized: "Seerr couldn't identify this title.", comment: "Shown when Crucible finds no TMDB id for a title")

    package static let requests = String(localized: "Requests", comment: "Title of the Seerr requests screen and its row")
    package static let myRequests = String(localized: "Mine", comment: "Requests screen filter: the viewer's own requests")
    package static let everyone = String(localized: "Everyone", comment: "Requests screen filter: every request, for whoever approves them")
    package static let awaiting = String(localized: "Awaiting Approval", comment: "Requests screen filter: requests waiting for approval")
    package static let noRequestsTitle = String(localized: "No Requests Yet", comment: "Empty requests screen title")
    package static let noRequestsText = String(localized: "Titles you request from your watchlist or a show's page appear here.", comment: "Empty requests screen message")
    package static let approve = String(localized: "Approve", comment: "Button that approves a Seerr request")
    package static let decline = String(localized: "Decline", comment: "Button that declines a Seerr request")
    package static let retry = String(localized: "Retry", comment: "Button that retries a failed Seerr request")
    package static let remove = String(localized: "Remove Request", comment: "Button that removes a Seerr request")

    package static func requestedBy(_ name: String) -> String {
        String(localized: "Requested by \(name)", comment: "Under a request on the requests screen, naming who asked")
    }

    package static func pendingCount(_ count: Int) -> String {
        String(localized: "\(count) awaiting approval", comment: "Seerr settings and You row: how many requests wait for approval")
    }

    /// A short label for where a title stands, for a badge or a button.
    package static func label(_ availability: SeerrAvailability) -> String {
        switch availability {
        case .notRequested: return String(localized: "Not Requested", comment: "Seerr state: nobody asked for it")
        case .pending: return String(localized: "Awaiting Approval", comment: "Seerr state: asked for, waiting for approval")
        case .approved: return String(localized: "Approved", comment: "Seerr state: approved, not downloading yet")
        case .downloading(let progress, _):
            guard let progress else { return String(localized: "Downloading", comment: "Seerr state: downloading, size unknown") }
            return String(localized: "Downloading \(Int((progress * 100).rounded()))%", comment: "Seerr state: downloading, with percent done")
        case .partiallyAvailable: return String(localized: "Partly on Your Server", comment: "Seerr state: some seasons arrived")
        case .available: return String(localized: "On Your Server", comment: "Seerr state: arrived and ready to play")
        case .declined: return String(localized: "Declined", comment: "Seerr state: the request was declined")
        case .failed: return String(localized: "Failed", comment: "Seerr state: Sonarr or Radarr could not add it")
        case .blocklisted: return String(localized: "Blocklisted", comment: "Seerr state: on Seerr's blocklist")
        }
    }

    /// A line under the state, when there is more to say: when a download should finish.
    package static func detail(_ availability: SeerrAvailability, now: Date = Date()) -> String? {
        guard case .downloading(_, let eta) = availability, let eta, eta > now else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(localized: "Ready \(formatter.localizedString(for: eta, relativeTo: now))", comment: "When a download should finish, e.g. Ready in 2 hours")
    }

    /// Where a title stands, short and in sentence case for the line under its poster.
    package static func cardLabel(_ availability: SeerrAvailability) -> String {
        switch availability {
        case .available: return seasonStatus(.available)
        case .notRequested: return seasonStatus(.missing)
        case .partiallyAvailable: return String(localized: "Partly on your server", comment: "Under a poster: some seasons of the show arrived")
        case .pending: return String(localized: "Awaiting approval", comment: "Under a poster: requested, waiting for approval")
        default: return label(availability)
        }
    }

    package static func symbol(_ availability: SeerrAvailability) -> String {
        switch availability {
        case .notRequested: return "plus.circle"
        case .pending: return "hourglass"
        case .approved: return "checkmark.circle"
        case .downloading: return "arrow.down.circle"
        case .partiallyAvailable: return "circle.lefthalf.filled"
        case .available: return "play.circle"
        case .declined: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .blocklisted: return "nosign"
        }
    }

    package static func seasonStatus(_ status: SeerrSeasonState.Status) -> String {
        switch status {
        case .missing: return String(localized: "Not on your server", comment: "Season state: missing")
        case .requested: return String(localized: "Requested", comment: "Season state: asked for")
        case .processing: return String(localized: "On its way", comment: "Season state: approved or downloading")
        case .partiallyAvailable: return String(localized: "Some episodes", comment: "Season state: some episodes arrived")
        case .available: return String(localized: "On your server", comment: "Season state: arrived")
        }
    }

    package static func seasonName(_ season: SeerrSeasonState) -> String {
        if let name = season.name, !name.isEmpty { return name }
        return String(localized: "Season \(season.number)", comment: "A season of a show, e.g. Season 2")
    }
}
