import Foundation

/// Words only the iPhone demo screens say. The ones both platforms share live in `DemoCopy`.
package enum DemoPhoneCopy {
    package static let startingStatus = String(localized: "Starting the demo…")
    package static let failureTitle = String(localized: "Couldn't start the demo")
    package static let failureMessage = String(localized: "The demo library didn't start. Try again, or sign in with Plex to use your own library.")
    package static let introReal = String(localized: "The app is the real thing: playback, downloads, search and Statistics work just as they do with your own server.")
    package static let thingsToTry = String(localized: "Things to try")
    package static let showMe = String(localized: "Show me")
    package static let leaveTitle = String(localized: "Leave the demo")
    package static let leaveConfirmTitle = String(localized: "Leave the demo?")
    package static let leaveConfirmMessage = String(localized: "The demo library and your progress in it are removed, and you return to the welcome screen.")
    package static let tourFooter = String(localized: "Everything here is fictional. All of Crucible is unlocked while the demo runs.")
    package static let unlockProTitle = String(localized: "Unlock Crucible Pro")
    package static let unlockProDetail = String(localized: "Unlock downloads, full Statistics and the poster")
    package static let stepDone = String(localized: "Done", comment: "Demo tour step is complete")
    package static let stepNotDone = String(localized: "Not done yet", comment: "Demo tour step is not complete")
    package static let downloadQueued = String(localized: "Download started")

    package static func progress(done: Int, total: Int) -> String {
        String(localized: "\(done) of \(total) done")
    }
}
