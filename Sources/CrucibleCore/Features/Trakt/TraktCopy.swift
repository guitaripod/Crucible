import Foundation

/// The words of the Trakt integration, shared by iPhone, iPad and Apple TV.
package enum TraktCopy {
    package static let name = "Trakt"
    package static let tagline = String(localized: "Track what you watch, everywhere", comment: "Subtitle of the Trakt integration")
    package static let disclaimer = String(localized: "Crucible uses Trakt but is not endorsed or certified by Trakt.", comment: "Required Trakt attribution line in Settings")
    package static let integrationsTitle = String(localized: "Integrations", comment: "Settings category for services such as Trakt")
    package static let integrationsExplanation = String(localized: "Services Crucible can work with. Each stays off, and sends nothing, until you connect it.", comment: "Explanation of the Integrations settings category")

    package static let connect = String(localized: "Connect Trakt", comment: "Button that starts connecting a Trakt account")
    package static let reconnect = String(localized: "Connect Again", comment: "Button that reconnects a Trakt account whose sign-in Trakt refused")
    package static let disconnect = String(localized: "Disconnect", comment: "Button that disconnects the Trakt account")
    package static let disconnectTitle = String(localized: "Disconnect Trakt?", comment: "Confirmation title for disconnecting Trakt")
    package static let disconnectMessage = String(localized: "Crucible stops sending to Trakt, tells Trakt to forget its access, and deletes what it kept about your Trakt account on this device. Your history on Trakt stays.", comment: "Confirmation message for disconnecting Trakt")

    package static let pitchSend = String(localized: "Records what you play as you play it, downloads too", comment: "First line of the Trakt pitch: scrobbling")
    package static let pitchChanges = String(localized: "Sends what you mark watched, your ratings and your check-ins", comment: "Second line of the Trakt pitch")
    package static let pitchScores = String(localized: "Shows Trakt's score next to IMDb and Rotten Tomatoes on every title", comment: "Third line of the Trakt pitch")
    package static let consentTitle = String(localized: "What Trakt receives", comment: "Heading of the list of data sent to Trakt")
    package static let consentPlays = String(localized: "What you play, when, and how far", comment: "Data sent to Trakt: playback")
    package static let consentRatings = String(localized: "The ratings and watched marks you change", comment: "Data sent to Trakt: ratings and watched state")
    package static let consentNever = String(localized: "Midgar never receives any of it. Disconnect at any time to revoke access and delete what Crucible kept.", comment: "Privacy promise under the Trakt consent list")

    package static let approveTitle = String(localized: "Approve Crucible on Trakt", comment: "Title of the Trakt device-code screen")
    package static let approveMessage = String(localized: "Open Trakt on any phone or computer, sign in and enter this code.", comment: "Instruction on the Trakt device-code screen")
    package static let openTrakt = String(localized: "Open Trakt", comment: "Button that opens the Trakt activation page")
    package static let copyCode = String(localized: "Copy Code", comment: "Button that copies the Trakt code")
    package static let codeCopied = String(localized: "Copied", comment: "Shown after the Trakt code was copied")
    package static let requestingCode = String(localized: "Getting a code…", comment: "Status while Crucible asks Trakt for a code")
    package static let waiting = String(localized: "Waiting for approval…", comment: "Status while Crucible waits for the viewer to approve the code on Trakt")
    package static let expired = String(localized: "This code expired. Get a new one to try again.", comment: "Status when the Trakt code expired")
    package static let denied = String(localized: "The code was declined on Trakt.", comment: "Status when the viewer declined the Trakt code")
    package static let notAllowed = String(localized: "Trakt isn't letting this account connect to Crucible yet.", comment: "Status when Trakt refuses the account, for example for a development app")
    package static let newCode = String(localized: "Get a New Code", comment: "Button that requests a new Trakt code")
    package static let scanToApprove = String(localized: "Scan to approve with your phone", comment: "Caption under the QR code on Apple TV")

    package static func approveAt(_ host: String) -> String {
        String(localized: "On your phone or computer, go to \(host)", comment: "Apple TV instruction naming the Trakt activation address")
    }

    package static let restricted = String(localized: "This Plex Home profile can't connect services. The account owner can, on their own profile.", comment: "Shown on a restricted Home profile instead of Connect Trakt")
    package static let unavailable = String(localized: "This build of Crucible doesn't include Trakt.", comment: "Shown when the build has no Trakt client ID")
    package static let needsReconnect = String(localized: "Trakt signed Crucible out. Connect again to keep scrobbling.", comment: "Shown when Trakt refused the token")

    package static let sectionFree = String(localized: "Sending to Trakt", comment: "Trakt settings section for scrobbling and sent changes")
    package static let scrobble = String(localized: "Scrobble Playback", comment: "Trakt setting that sends playback as it happens")
    package static let scrobbleDetail = String(localized: "Live progress while you watch, and plays from downloads once you're online.", comment: "Explanation of the scrobble setting")
    package static let sendChanges = String(localized: "Send Changes", comment: "Trakt setting that sends watched marks, ratings and check-ins")
    package static let sendChangesDetail = String(localized: "What you mark watched, your ratings and check-ins.", comment: "Explanation of the Send Changes setting")
    package static let removeOnUnwatch = String(localized: "Unwatched Removes Plays", comment: "Trakt setting: marking unwatched removes plays on Trakt")
    package static let removeOnUnwatchDetail = String(localized: "Marking a title unwatched also removes its plays from your Trakt history.", comment: "Explanation of the Unwatched Removes Plays setting")
    package static let anotherApp = String(localized: "Another App Records My Plays", comment: "Trakt setting for when another scrobbler already records plays")
    package static let anotherAppDetail = String(localized: "Turn on if Trakt's own Plex sync, PlexTraktSync or a webhook already records them, so nothing counts twice.", comment: "Explanation of the Another App Records My Plays setting")
    package static let waitingChanges = String(localized: "Waiting to Send", comment: "Trakt settings row with the number of queued changes")
    package static let unmatched = String(localized: "Not Found on Trakt", comment: "Trakt settings row listing titles Crucible could not match")
    package static let unmatchedDetail = String(localized: "Crucible matches titles by the IMDb, TMDB and TVDB ids your server knows. These had none Trakt recognises, so nothing about them is sent.", comment: "Explanation of the unmatched titles list")

    package static let doublePlayTitle = String(localized: "Trakt already records plays from this server", comment: "Title of the double-scrobble question")
    package static let doublePlayMessage = String(localized: "Trakt's own Plex sync is on. If both record, every episode counts twice. Pick one.", comment: "Message of the double-scrobble question")
    package static let crucibleRecords = String(localized: "Crucible Records Plays", comment: "Double-scrobble choice: Crucible scrobbles and Trakt's Plex scrobbler is turned off")
    package static let crucibleRecordsDetail = String(localized: "Live progress and plays from downloads. Trakt's Plex scrobbler is turned off; its other settings stay.", comment: "Explanation of choosing Crucible to record plays")
    package static let traktRecords = String(localized: "Trakt's Plex Sync Records Them", comment: "Double-scrobble choice: Trakt keeps recording, Crucible stops scrobbling")
    package static let traktRecordsDetail = String(localized: "Crucible stops scrobbling and keeps everything else.", comment: "Explanation of choosing Trakt's Plex sync to record plays")

    package static let markedWatched = String(localized: "Marked watched on Trakt", comment: "Banner in the player when Trakt recorded the play")
    package static let checkIn = String(localized: "Check In", comment: "Action that tells Trakt you are watching this now")
    package static let checkedIn = String(localized: "Checked in on Trakt", comment: "Confirmation after a Trakt check-in")
    package static let cancelCheckIn = String(localized: "Cancel Check-In", comment: "Action that cancels the current Trakt check-in")
    package static let checkInCancelled = String(localized: "Check-in cancelled", comment: "Confirmation after cancelling a Trakt check-in")
    package static let checkInNotMatched = String(localized: "Trakt doesn't know this title, so Crucible can't check in to it.", comment: "Check-in failure for an unmatched title")
    package static let replaceCheckIn = String(localized: "Replace", comment: "Button that cancels the current Trakt check-in for a new one")

    package static func alreadyCheckedIn(until time: String?) -> String {
        guard let time else {
            return String(localized: "You're already checked in to something else on Trakt.", comment: "Check-in conflict without an end time")
        }
        return String(localized: "You're already checked in to something else on Trakt until \(time).", comment: "Check-in conflict with the time it ends")
    }

    package static let ratingsTitle = String(localized: "Ratings", comment: "Title of the ratings strip on a detail page")

    package static func sourceName(_ source: TraktScore.Source) -> String {
        switch source {
        case .trakt: return "Trakt"
        case .imdb: return "IMDb"
        case .tmdb: return "TMDB"
        case .rottenTomatoes: return "Rotten Tomatoes"
        case .metascore: return "Metacritic"
        case .letterboxd: return "Letterboxd"
        case .myAnimeList: return "MyAnimeList"
        }
    }

    /// The score as its source writes it: a percentage for Trakt and Rotten Tomatoes, out of 5 for Letterboxd, out of 100 for
    /// Metacritic and out of 10 for the rest.
    package static func value(_ score: TraktScore) -> String {
        switch score.source {
        case .trakt: return "\(Int((score.value * 10).rounded()))%"
        case .rottenTomatoes: return "\(Int(score.value.rounded()))%"
        case .metascore: return "\(Int(score.value.rounded()))"
        case .letterboxd: return String(format: "%.1f", locale: Formatters.interfaceLocale, score.value)
        case .imdb, .tmdb, .myAnimeList: return String(format: "%.1f", locale: Formatters.interfaceLocale, score.value)
        }
    }

    /// The line under a score: its votes when Trakt says, else what the number is out of.
    package static func detail(_ score: TraktScore) -> String {
        if let votes = score.votes, votes > 0 {
            return String(localized: "\(Formatters.compactCount(votes)) votes", comment: "Number of votes under a score, e.g. 12K votes")
        }
        switch score.source {
        case .letterboxd: return String(localized: "of 5", comment: "Under a Letterboxd score")
        case .metascore: return String(localized: "of 100", comment: "Under a Metacritic score")
        case .rottenTomatoes: return String(localized: "Tomatometer", comment: "Under a Rotten Tomatoes score")
        default: return String(localized: "of 10", comment: "Under a score out of ten")
        }
    }

    package static func accessibilityLabel(_ score: TraktScore) -> String {
        "\(sourceName(score.source)), \(value(score)), \(detail(score))"
    }

    package static func pendingCount(_ count: Int) -> String {
        String(localized: "\(count) waiting", comment: "Number of Trakt changes waiting to be sent")
    }

    package static let privacyStatementConnected = String(localized: "Crucible has no analytics, no ads and no tracking. It talks to your Plex server, to plex.tv, and to Trakt because you connected it. Your statistics and settings stay on this device.", comment: "Privacy statement in Settings while Trakt is connected")
}
