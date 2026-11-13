import Foundation

/// The words of What to Watch on iPhone, iPad and Apple TV.
package enum WatchCopy {
    package static let title = String(localized: "What to Watch", comment: "Name of the feature that picks films and series from a sentence")
    package static let placeholder = String(localized: "Something funny, under two hours", comment: "Example request shown in the What to Watch field")
    package static let suggest = String(localized: "Suggest", comment: "Button that asks What to Watch for picks")
    package static let tryAgain = String(localized: "Try Again")
    package static let typeYourOwn = String(localized: "Say or Type Your Own", comment: "Apple TV button that opens a text field for a What to Watch request")
    package static let tileSubtitle = String(localized: "Picks from your library", comment: "Subtitle of the What to Watch tile on Apple TV Home")

    /// What a person is told before they ask: what is chosen, and what leaves the device to choose it. In the demo
    /// nothing leaves it, and the line says which requests the demo answers.
    package static var explanation: String {
        guard HostedBrain.takesAnyRequest else {
            return String(localized: "The demo answers these four requests with picks prepared ahead, and nothing leaves this device. With your own library you can ask for anything.", comment: "What to Watch in the demo, under its four example requests")
        }
        return String(localized: "Say what you feel like and Crucible picks from your own library. Your words and the titles, years, genres, lengths, ratings and watched state of your films and series go to Crucible's AI to choose. Nothing else leaves this device.", comment: "What to Watch: what is sent to the hosted model")
    }

    /// Requests a person can pick to see what to ask for.
    package static let examples = [
        String(localized: "A film I haven't seen, under two hours", comment: "Example What to Watch request"),
        String(localized: "Something light for tonight", comment: "Example What to Watch request"),
        String(localized: "A series to start this weekend", comment: "Example What to Watch request"),
        String(localized: "For the whole family", comment: "Example What to Watch request"),
    ]

    package static func step(_ step: WatchStep) -> String {
        switch step {
        case .readingLibrary: return String(localized: "Reading your library…", comment: "What to Watch progress")
        case .understanding: return String(localized: "Working out what you mean…", comment: "What to Watch progress")
        case .choosing: return String(localized: "Choosing…", comment: "What to Watch progress")
        }
    }

    /// "1995 · 1h 46m · Watched", the line under a pick's title, from what the library knows.
    package static func facts(_ title: WatchTitle) -> String {
        var parts: [String] = []
        if let year = title.year { parts.append(String(year)) }
        if let minutes = title.minutes, let runtime = DetailFormat.runtime(Double(minutes * 60)) { parts.append(runtime) }
        switch title.seen {
        case .seen: parts.append(String(localized: "Watched"))
        case .started: parts.append(String(localized: "Started", comment: "A series the person has watched some episodes of"))
        case .unseen: break
        }
        return parts.joined(separator: " · ")
    }

    /// What went wrong, the cause and what to do next.
    package static func failure(_ failure: WatchFailure) -> String {
        switch failure {
        case .emptyLibrary:
            return String(localized: "There is nothing to choose from yet. Add films or series to your Plex library, then ask again.")
        case .libraryUnreachable:
            return String(localized: "Couldn't read your library because your Plex server isn't answering. Check that it is on, then try again.")
        case .nothingFits(let note):
            return note.isEmpty ? String(localized: "Nothing in your library fits that. Try saying it another way.") : note
        case .brain(let error):
            return refusal(error)
        }
    }

    /// What the person is told when Crucible's AI gave no answer.
    private static func refusal(_ error: HostedBrainError) -> String {
        switch error {
        case .unavailable:
            return String(localized: "What to Watch isn't part of this build of Crucible.")
        case .offline:
            return String(localized: "Couldn't choose because Crucible's AI couldn't be reached. Check your connection and try again.")
        case .needsPro:
            return String(localized: "Couldn't choose because What to Watch comes with Crucible Pro.")
        case .allowanceUsed(let resetsAt):
            let time = resetsAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "Couldn't choose because today's AI allowance is used up. It comes back at \(time).", comment: "The placeholder is a time of day, e.g. 2:00")
        case .busy:
            return String(localized: "Couldn't choose because Crucible's AI is busy. Try again in a minute.")
        case .declined:
            return String(localized: "Couldn't choose from that. Describe what you want to watch.")
        case .failed:
            return String(localized: "Couldn't choose because Crucible's AI is unavailable right now. Try again in a few minutes.")
        }
    }

    /// Whether asking again as it stands is the way forward, rather than asking for something else.
    package static func canRetry(_ failure: WatchFailure) -> Bool {
        switch failure {
        case .libraryUnreachable, .brain(.offline), .brain(.busy), .brain(.failed): return true
        case .emptyLibrary, .nothingFits, .brain(.unavailable), .brain(.needsPro), .brain(.allowanceUsed), .brain(.declined): return false
        }
    }
}
