import Foundation

/// The words of Sports Research on iPhone, iPad and Apple TV.
package enum SportsCopy {
    package static var title: String { String(localized: "Sports Research", comment: "Title of the Sports Research screen and feature") }

    package static var pitch: String {
        String(localized: "Plex has no agent for sports, so recordings show up under their file names. Your Crucible Server's own model looks each event up on the web and gives it a real title, date, card and poster in Plex. It runs on your computer with the model you run there, and it never touches the files.", comment: "Sports Research explanation at the top of its screen")
    }

    package static var forWhom: String {
        String(localized: "It is made for people who run a capable model at home: one that calls tools, searches the web and thinks before it answers.", comment: "Sports Research: who the feature is for")
    }

    package static var requirementsHeader: String { String(localized: "What it needs", comment: "Sports Research section header above the list of requirements") }
    package static var settingsHeader: String { String(localized: "Your choices", comment: "Sports Research section header above the owner's settings") }
    package static var nowHeader: String { String(localized: "Now", comment: "Sports Research section header for what the server is doing") }
    package static var resultsHeader: String { String(localized: "Results", comment: "Sports Research section header above researched files") }

    package static func progress(done: Int, of total: Int) -> String {
        String(localized: "Ready: \(done) of \(total)", comment: "Sports Research: how many requirements are met, e.g. Ready: 7 of 9")
    }

    package static var allReady: String { String(localized: "Everything is ready.", comment: "Sports Research: every requirement is met") }
    package static var ownerOnly: String {
        String(localized: "Only the owner of this Plex server can change Sports Research.", comment: "Sports Research footer for people who are not the server owner")
    }

    package static func groupTitle(_ group: SportsRequirement.Group) -> String {
        switch group {
        case .plex: String(localized: "Plex", comment: "Sports Research requirement group: the Plex server")
        case .model: String(localized: "Your model", comment: "Sports Research requirement group: the model on the owner's computer")
        case .web: String(localized: "The web", comment: "Sports Research requirement group: web search")
        case .library: String(localized: "Your library", comment: "Sports Research requirement group: the libraries it reads")
        }
    }

    package static func title(_ requirement: SportsRequirement) -> String {
        switch requirement {
        case .owner: String(localized: "Signed in as the owner", comment: "Sports Research requirement title")
        case .model: String(localized: "A model on your computer", comment: "Sports Research requirement title")
        case .tools: String(localized: "Calls tools", comment: "Sports Research requirement title: the model calls tools on its own")
        case .thinking: String(localized: "Thinks first", comment: "Sports Research requirement title: the model reasons before answering")
        case .context: String(localized: "Room to read", comment: "Sports Research requirement title: a large enough context window")
        case .search: String(localized: "Web search", comment: "Sports Research requirement title")
        case .agreement: String(localized: "Your agreement", comment: "Sports Research requirement title: the owner agrees where searches go")
        case .libraries: String(localized: "A sports library", comment: "Sports Research requirement title")
        case .on: String(localized: "Switched on", comment: "Sports Research requirement title")
        }
    }

    package static func why(_ requirement: SportsRequirement) -> String {
        switch requirement {
        case .owner: String(localized: "Titles and posters are written into your library as you, the owner of this Plex server.", comment: "Why Sports Research needs the owner's sign-in")
        case .model: String(localized: "The research runs on the model you set for Crucible Server, so it costs nothing per file.", comment: "Why Sports Research needs a model")
        case .tools: String(localized: "The model searches and reads pages by itself, which takes a model that calls tools on its own.", comment: "Why Sports Research needs tool calling")
        case .thinking: String(localized: "A model that reasons before it acts checks the event number, date and card instead of guessing.", comment: "Why Sports Research needs a thinking model")
        case .context: String(localized: "Event pages are long, so the model needs a context window of at least 32K tokens.", comment: "Why Sports Research needs a large context window")
        case .search: String(localized: "Searches go through a search engine you choose, such as your own SearXNG.", comment: "Why Sports Research needs a search engine")
        case .agreement: String(localized: "Searches name the events in your files, such as \"UFC 334 prelims\", and go only to the search engine you set.", comment: "What the Sports Research agreement covers")
        case .libraries: String(localized: "Choose the Other Videos libraries that hold your sports recordings.", comment: "Why Sports Research needs a library")
        case .on: String(localized: "Research runs by itself whenever new files arrive.", comment: "What switching Sports Research on does")
        }
    }

    package static func state(_ state: SportsCheck.State) -> String {
        switch state {
        case .done: String(localized: "Ready", comment: "Sports Research requirement state")
        case .missing: String(localized: "Not set up", comment: "Sports Research requirement state")
        case .failed: String(localized: "Needs attention", comment: "Sports Research requirement state")
        }
    }

    package static var belowInChoices: String { String(localized: "Set it under Your choices below.", comment: "Sports Research: a requirement the owner meets with the controls further down the screen") }

    package static var researchNewFiles: String { String(localized: "Research new files", comment: "Sports Research toggle") }
    package static var agree: String { String(localized: "Agree", comment: "Sports Research button: agree to where searches go") }
    package static func agreeQuestion(_ destination: String) -> String {
        String(localized: "Searches naming the events in your sports files go to \(destination), and public web pages are read from the computer with Plex. Your library, files and watch history are not sent.", comment: "Sports Research agreement text; the argument names the search engine")
    }

    package static var withdraw: String { String(localized: "Withdraw agreement", comment: "Sports Research button: take back the agreement") }
    package static var checkAgain: String { String(localized: "Check again", comment: "Sports Research button: run every check again") }
    package static var lookNow: String { String(localized: "Look for new files now", comment: "Sports Research button") }
    package static var researchAgain: String { String(localized: "Research again", comment: "Sports Research action on one file") }
    package static var copyCommand: String { String(localized: "Copy command", comment: "Sports Research: copy a command to run on the server") }
    package static var onTheServer: String { String(localized: "On the computer with Plex:", comment: "Sports Research: introduces a command to run on the server") }
    package static var noLibraries: String {
        String(localized: "Plex has no Other Videos library. Add one for your sports recordings in Plex, then check again.", comment: "Sports Research: no library to choose")
    }

    package static func phase(_ status: SportsStatus) -> String {
        switch status.phase {
        case "looking": String(localized: "Looking for new files", comment: "Sports Research server phase")
        case "researching": String(localized: "Researching", comment: "Sports Research server phase")
        case "writing": String(localized: "Writing to Plex", comment: "Sports Research server phase")
        case "waiting": String(localized: "Waiting until everything is ready", comment: "Sports Research server phase")
        default: String(localized: "Up to date", comment: "Sports Research server phase: nothing left to research")
        }
    }

    package static func queued(_ count: Int) -> String {
        String(localized: "Waiting: \(count)", comment: "Sports Research: how many files wait to be researched, e.g. Waiting: 3")
    }

    package static func lastLooked(_ date: Date, now: Date = Date()) -> String {
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        return String(localized: "Last looked \(relative)", comment: "Sports Research: when the server last looked at the libraries, e.g. Last looked 5 minutes ago")
    }

    package static func itemState(_ state: String) -> String {
        switch state {
        case "matched": String(localized: "Matched", comment: "Sports Research file state")
        case "attention": String(localized: "Needs a look", comment: "Sports Research file state: the model could not identify it")
        case "edited": String(localized: "Edited by you", comment: "Sports Research file state: the owner changed it in Plex")
        default: String(localized: "Will try again", comment: "Sports Research file state: a temporary failure")
        }
    }

    package static func itemSymbol(_ state: String) -> String {
        switch state {
        case "matched": "checkmark.circle.fill"
        case "attention": "questionmark.circle.fill"
        case "edited": "pencil.circle.fill"
        default: "arrow.clockwise.circle.fill"
        }
    }

    package static func counts(_ board: SportsBoard) -> String {
        let matched = board.count("matched")
        let attention = board.count("attention")
        if attention > 0 {
            return String(localized: "Matched: \(matched) · Needs a look: \(attention)", comment: "Sports Research results summary, e.g. Matched: 40 · Needs a look: 2")
        }
        return String(localized: "Matched: \(matched)", comment: "Sports Research results summary, e.g. Matched: 40")
    }

    package static var nothingYet: String {
        String(localized: "Nothing researched yet. Files appear here as the server works through them.", comment: "Sports Research: no results yet")
    }

    package static var updateServer: String {
        String(localized: "This Crucible Server is from before Sports Research. Update it on the computer with Plex, then come back.", comment: "Sports Research: the paired server is too old")
    }

    package static var proPitch: String {
        String(localized: "Sports Research is part of Crucible Pro.", comment: "Sports Research: the feature needs Pro")
    }
}
