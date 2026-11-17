import Foundation

/// The words of the welcome, shared by iPhone, iPad, Apple TV and Linux.
package enum WelcomeCopy {
    /// A single line of the welcome: a symbol, a name and what it does.
    package struct Highlight: Equatable, Hashable, Sendable {
        package let symbol: String
        package let title: String
        package let detail: String

        package init(symbol: String, title: String, detail: String) {
            self.symbol = symbol
            self.title = title
            self.detail = detail
        }
    }

    package static let title = String(localized: "Welcome to Crucible", comment: "Title of the welcome shown the first time a library opens on a device")
    package static let start = String(localized: "Start Watching", comment: "Button that closes the welcome and shows the library")
    package static let seePro = String(localized: "See Crucible Pro")

    package static func connected(to server: String) -> String {
        String(localized: "Connected to \(server)")
    }

    static func title(of standing: WelcomePlan.Standing) -> String {
        switch standing {
        case .checking:
            return String(localized: "Your library is ready", comment: "Welcome heading while the App Store has not said whether the viewer has Crucible Pro")
        case .freeWeekAhead, .free:
            return String(localized: "Free to watch, for good", comment: "Welcome heading for a viewer without Crucible Pro")
        case .proWeek:
            return String(localized: "Your Pro week is on", comment: "Welcome heading during the free Pro week")
        case .trial:
            return String(localized: "Your Crucible Pro trial is on")
        case .pro:
            return String(localized: "Crucible Pro is yours", comment: "Welcome heading for a viewer who bought Crucible Pro")
        case .included:
            return String(localized: "Everything is open", comment: "Welcome heading in a build where every feature is included")
        }
    }

    static func message(of standing: WelcomePlan.Standing, isLinux: Bool = AppPlatform.isLinux) -> String {
        switch standing {
        case .checking:
            return String(localized: "Play, browse and search everything on your server.", comment: "Welcome message while the App Store has not answered")
        case .freeWeekAhead:
            return String(localized: "Watching, browsing and your history are free. Finish your first film or episode and Crucible Pro is yours for a week, with nothing charged and nothing renewing.", comment: "Welcome message for a free viewer whose Pro week has not started")
        case .free:
            return String(localized: "Watching, browsing and your history are free. Crucible Pro adds more whenever you want it.", comment: "Welcome message for a free viewer whose Pro week is over")
        case .proWeek(let endsAt):
            let date = ProWeek.endDateText(endsAt)
            return String(localized: "Everything in Crucible Pro is open until \(date). Nothing is charged and nothing renews.", comment: "Welcome message during the Pro week, with its end date")
        case .trial(let endsAt):
            guard let endsAt else {
                return String(localized: "Everything in Crucible Pro is open.", comment: "Welcome message during a free trial without a known end")
            }
            let date = ProWeek.endDateText(endsAt)
            return String(localized: "Everything in Crucible Pro is open until \(date).", comment: "Welcome message during a free trial, with its end date")
        case .pro(let familyShared):
            return familyShared
                ? String(localized: "Your family shares Crucible Pro with you, so everything is open.", comment: "Welcome message for Pro shared through Family Sharing")
                : String(localized: "Thank you for supporting Crucible. Everything is open, on every device that uses your Apple Account.", comment: "Welcome message for a viewer who bought Crucible Pro")
        case .included:
            return isLinux
                ? String(localized: "Crucible on Linux is free, with every feature open.", comment: "Welcome message on Linux")
                : String(localized: "This build of Crucible includes every feature.", comment: "Welcome message in a source build")
        }
    }

    static func symbol(of standing: WelcomePlan.Standing) -> String {
        switch standing {
        case .checking: return "play.rectangle.on.rectangle"
        case .freeWeekAhead, .free: return "play.circle"
        case .proWeek, .trial: return "gift"
        case .pro: return "heart.fill"
        case .included: return "checkmark.seal"
        }
    }

    package static func freeHighlights(includingDownloads: Bool) -> [Highlight] {
        var highlights = [
            Highlight(
                symbol: "play.rectangle",
                title: String(localized: "Plays everything", comment: "Welcome highlight title: playback"),
                detail: String(localized: "Direct play or transcoding, Skip Intro and Credits, and the next episode at the credits.", comment: "Welcome highlight detail: playback")
            ),
            Highlight(
                symbol: "rectangle.stack",
                title: String(localized: "Your whole library", comment: "Welcome highlight title: browsing"),
                detail: String(localized: "Collections, playlists, cast and crew, trailers and what your server is missing.", comment: "Welcome highlight detail: browsing")
            ),
        ]
        if includingDownloads {
            highlights.append(Highlight(
                symbol: "arrow.down.circle",
                title: String(localized: "Take it with you", comment: "Welcome highlight title: downloads"),
                detail: String(localized: "Download films and episodes to watch offline, with your place and the skips kept.", comment: "Welcome highlight detail: downloads")
            ))
        }
        highlights.append(Highlight(
            symbol: "star.leadinghalf.filled",
            title: String(localized: "Rate and remember", comment: "Welcome highlight title: ratings and history"),
            detail: String(localized: "Half-star ratings saved to Plex, your watch history and this week's statistics.", comment: "Welcome highlight detail: ratings and history")
        ))
        return highlights
    }

    // MARK: - Trakt

    package static let traktInviteTitle = String(localized: "See what everyone thinks", comment: "Title of the invitation to connect Trakt")
    package static let traktInviteMessage = String(localized: "Connect Trakt for its score beside IMDb and Rotten Tomatoes on every title, with reviews and what people say. Everything you watch is checked off on Trakt by itself.", comment: "Welcome invitation to connect Trakt")
    package static let traktConnectedTitle = String(localized: "Trakt is connected", comment: "Welcome line when Trakt is already connected")

    package static func traktConnectedMessage(username: String?) -> String {
        guard let username else {
            return String(localized: "Scores, reviews and what people say are on every title.", comment: "Welcome line when Trakt is connected, without the account name")
        }
        return String(localized: "Signed in as \(username). Scores, reviews and what people say are on every title.", comment: "Welcome line when Trakt is connected, with the Trakt account name")
    }

    package static func title(of step: WelcomePlan.TraktStep) -> String {
        switch step {
        case .invite: return traktInviteTitle
        case .reconnect: return TraktCopy.name
        case .connected: return traktConnectedTitle
        }
    }

    package static func message(of step: WelcomePlan.TraktStep) -> String {
        switch step {
        case .invite: return traktInviteMessage
        case .reconnect: return TraktCopy.needsReconnect
        case .connected(let username): return traktConnectedMessage(username: username)
        }
    }

    /// The button of the Trakt step, or nil once Trakt is connected.
    package static func action(of step: WelcomePlan.TraktStep) -> String? {
        switch step {
        case .invite: return TraktCopy.connect
        case .reconnect: return TraktCopy.reconnect
        case .connected: return nil
        }
    }
}
