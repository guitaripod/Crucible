import Foundation

/// The words every platform uses for a title the app cannot play here, which its mark takes out of the app on every
/// device of the server (`IncompatibleTitles`).
package enum IncompatibleCopy {
    package static let title = String(localized: "Incompatible Titles", comment: "Settings row and screen listing the titles the app left out because they cannot play here")

    package static let explanation = String(localized: "Titles that would not play here, left out of Home, search and your libraries.", comment: "Explanation of the Incompatible Titles setting")

    package static let footer = String(localized: "Each title carries the label “Crucible Incompatible” on your Plex server, so every device connected to it leaves them out. Removing the label in Plex takes a title out of this list too.", comment: "Footer of the Incompatible Titles screen, explaining that the mark lives on the Plex server as a label")

    package static let emptyTitle = String(localized: "Nothing Left Out", comment: "Incompatible Titles screen heading when no title is marked")

    package static let emptyExplanation = String(localized: "A title is marked when the server’s conversion arrives with no picture in it, or when you mark one from its menu.", comment: "Incompatible Titles screen explanation when no title is marked")

    package static let mark = String(localized: "Mark Incompatible", comment: "Action that hides a title from the app on every device because it cannot play here")

    package static let unmark = String(localized: "Show Again", comment: "Action that puts a title back in the app")

    package static let hideThisTitle = String(localized: "Hide This Title", comment: "Player alert button that marks the title incompatible and hides it everywhere")

    package static let hidden = String(localized: "Hidden on every device.", comment: "Toast after a title was marked incompatible and the Plex server took the mark")

    package static let hiddenHereOnly = String(localized: "Hidden here. Your server did not take the mark, so your other devices still show it.", comment: "Toast after a title was marked incompatible on this device only because the server refused the label")

    package static let thisDeviceOnly = String(localized: "This device only", comment: "Badge on a title left out only here because the server did not take the mark")

    package static func count(_ count: Int) -> String {
        String(localized: "\(count) titles", comment: "How many titles are marked incompatible, e.g. 3 titles")
    }
}
