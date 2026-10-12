import Foundation

/// Words only the iPhone demo screens say. The ones both platforms share live in `DemoCopy`.
package enum DemoPhoneCopy {
    package static let startingStatus = "Starting the demo…"
    package static let failureTitle = "Couldn't start the demo"
    package static let failureMessage = "The demo library didn't start. Try again, or sign in with Plex to use your own library."
    package static let introReal = "The app is the real thing: playback, downloads, search and Statistics work just as they do with your own server."
    package static let thingsToTry = "Things to try"
    package static let showMe = "Show me"
    package static let leaveTitle = "Leave the demo"
    package static let leaveConfirmTitle = "Leave the demo?"
    package static let leaveConfirmMessage = "The demo library and your progress in it are removed, and you return to the welcome screen."
    package static let tourFooter = "Everything here is fictional. All of Crucible is unlocked while the demo runs."
    package static let unlockProTitle = "Unlock Crucible Pro"
    package static let unlockProDetail = "Unlock downloads, full Statistics and the poster"
    package static let stepDone = "Done"
    package static let stepNotDone = "Not done yet"
    package static let downloadQueued = "Download started"

    package static func progress(done: Int, total: Int) -> String {
        "\(done) of \(total) done"
    }
}
