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
        let relative = PortableFormat.relative(date, to: now, width: .full)
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
        let attention = board.needingALookCount
        if attention > 0 {
            return String(localized: "Matched: \(matched) · Needs a look: \(attention)", comment: "Sports Research results summary, e.g. Matched: 40 · Needs a look: 2")
        }
        return String(localized: "Matched: \(matched)", comment: "Sports Research results summary, e.g. Matched: 40")
    }

    /// "14 Nov 2026 · Madison Square Garden" for a matched file, the note (or what to do) for one that needs a look.
    package static func meta(_ item: SportsItem) -> String {
        if item.state == "attention" || item.state == "failed" { return item.note.isEmpty ? attentionHelp : item.note }
        guard let detail = item.detail else { return "" }
        return [detail.day.map(day), detail.place.isEmpty ? nil : detail.place].compactMap { $0 }.joined(separator: " · ")
    }

    package static var nothingYet: String {
        String(localized: "Nothing researched yet. Files appear here as the server works through them.", comment: "Sports Research: no results yet")
    }

    package static var updateServer: String {
        String(localized: "This Crucible Server is from before Sports Research. Update it on the computer with Plex, then come back.", comment: "Sports Research: the paired server is too old")
    }

    /// What to say when the report could not be read: that the server needs an update only when it answered and has no
    /// Sports Research, else what went wrong, such as the server not answering.
    package static func failure(_ error: CompanionError, hasSports: Bool?) -> String {
        hasSports == false ? updateServer : error.message
    }

    package static var proPitch: String {
        String(localized: "Sports Research is part of Crucible Pro.", comment: "Sports Research: the feature needs Pro")
    }

    package static var howItWorks: String { String(localized: "How it works", comment: "Sports Research: header above the short explanation of what research does") }

    /// What research does, in four short rows: a symbol, a line and a sentence each.
    package static var howSteps: [(symbol: String, title: String, detail: String)] {
        [
            ("magnifyingglass", String(localized: "It finds the event", comment: "Sports Research how-it-works row title"), String(localized: "The model on your computer searches the web and reads event pages, checking the number, date and card.", comment: "Sports Research how-it-works row detail: finding the event")),
            ("photo.on.rectangle", String(localized: "It writes it into Plex", comment: "Sports Research how-it-works row title"), String(localized: "A real title, date, summary, card and poster, locked so Plex keeps them.", comment: "Sports Research how-it-works row detail: what gets written")),
            ("doc", String(localized: "Your files stay put", comment: "Sports Research how-it-works row title"), String(localized: "Nothing is renamed or moved, so downloads keep seeding.", comment: "Sports Research how-it-works row detail: files are untouched")),
            ("cpu", String(localized: "It runs on your hardware", comment: "Sports Research how-it-works row title"), String(localized: "Research uses the model you run for Crucible Server, so there is no cost per file.", comment: "Sports Research how-it-works row detail: runs on the owner's model")),
        ]
    }

    package static var whatYouNeed: String {
        String(localized: "What you need", comment: "Sports Research: header above the computer, graphics memory and model it needs")
    }

    /// The hardware and model research needs, in four short rows: a symbol, a line and a sentence each.
    package static var needs: [(symbol: String, title: String, detail: String)] {
        [
            ("desktopcomputer", String(localized: "A computer that stays on", comment: "Sports Research requirement row title: the computer running Plex"), String(localized: "The one with Plex and Crucible Server. Research runs there, never on this device.", comment: "Sports Research requirement row detail: where research runs")),
            ("memorychip", String(localized: "16 GB of graphics memory or more", comment: "Sports Research requirement row title: GPU memory"), String(localized: "24 GB is comfortable. On a Mac with Apple silicon, 32 GB of memory or more.", comment: "Sports Research requirement row detail: GPU memory and Apple silicon")),
            ("brain", String(localized: "A model that uses tools and thinks", comment: "Sports Research requirement row title: the kind of model"), String(localized: "About 20 billion parameters or more, with room for 32K tokens, served by llama-swap, Ollama or LM Studio. Smaller models get events wrong.", comment: "Sports Research requirement row detail: model size, context and servers")),
            ("timer", String(localized: "About a minute a file", comment: "Sports Research requirement row title: how long research takes"), String(localized: "Several files run at once on a fast graphics card. A large library takes a while the first time; after that, only new files.", comment: "Sports Research requirement row detail: how long a library takes")),
        ]
    }

    package static var whatChanges: String { String(localized: "What changes in Plex", comment: "Sports Research: heading of the example of a file before and after research") }
    package static var transformationLine: String {
        String(localized: "Your file name becomes a real title, date, card and poster. The file stays where it is.", comment: "Sports Research: what research does to a file, under the example")
    }
    package static var example: String { String(localized: "Example", comment: "Sports Research: label on an example result that is not from the person's library") }
    package static var latest: String { String(localized: "Latest", comment: "Sports Research: label on the newest researched file") }
    package static var exampleFile: String { "ufc.fight.night.286.nurmagomedov.vs.song.1080p.web.h264-verum.mkv" }
    package static var exampleTitle: String { "UFC Fight Night 286: Nurmagomedov vs. Song" }

    package static var setUpInFour: String { String(localized: "Set up in four steps", comment: "Sports Research: heading above the setup steps") }
    package static func stepOf(_ number: Int, _ total: Int) -> String {
        String(localized: "Step \(number) of \(total)", comment: "Sports Research: which setup step this is, e.g. Step 2 of 4")
    }

    package static func stepWhat(_ group: SportsRequirement.Group) -> String {
        switch group {
        case .plex: String(localized: "Sign in with the Plex account that owns this server.", comment: "Sports Research setup step 1: what to do")
        case .model: String(localized: "Run a model on your computer that calls tools and thinks first.", comment: "Sports Research setup step 2: what to do")
        case .web: String(localized: "Choose the search engine it may use, and agree to what it sends.", comment: "Sports Research setup step 3: what to do")
        case .library: String(localized: "Pick the Other Videos libraries with your recordings, and switch research on.", comment: "Sports Research setup step 4: what to do")
        }
    }

    package static var showSetup: String { String(localized: "Show setup", comment: "Sports Research: show the setup steps again") }
    package static var hideSetup: String { String(localized: "Hide setup", comment: "Sports Research: hide the setup steps") }
    package static var seePro: String { String(localized: "See Crucible Pro", comment: "Sports Research: open the Crucible Pro offer") }
    package static var shareCommand: String { String(localized: "Share command", comment: "Sports Research: share a command to run on the server") }
    package static var oneSwitch: String { String(localized: "One switch from ready", comment: "Sports Research: everything is set up except the switch") }
    package static var chooseLibraries: String { String(localized: "Choose libraries", comment: "Sports Research: button that opens the library choice") }

    package static var all: String { String(localized: "All", comment: "Sports Research: show every result") }
    package static var needsALook: String { String(localized: "Needs a look", comment: "Sports Research file state: the model could not identify it") }
    package static var nothingNeedsALook: String { String(localized: "Nothing needs a look.", comment: "Sports Research: no result needs the owner") }
    package static var attentionHelp: String {
        String(localized: "Crucible could not tell which event this is. Research it again, or rename the file so it names the event.", comment: "Sports Research: what to do about a file research could not identify")
    }

    package static var liveNow: String { String(localized: "Right now", comment: "Sports Research: heading of the live research card") }
    package static func elapsed(_ seconds: Int) -> String {
        String(localized: "\(duration(seconds)) elapsed", comment: "Sports Research: how long the current research has run, e.g. 1 min 12 s elapsed")
    }
    package static func model(_ name: String) -> String {
        String(localized: "Model: \(name)", comment: "Sports Research: the model doing the research")
    }

    package static func step(_ step: SportsLiveStep) -> String {
        switch step.kind {
        case .thinking: String(localized: "Thinking", comment: "Sports Research live step: the model is thinking")
        case .searching: String(localized: "Searching for \u{201C}\(step.detail)\u{201D}", comment: "Sports Research live step: the model searches the web for the quoted words")
        case .reading: String(localized: "Reading \(step.detail)", comment: "Sports Research live step: the model reads the named web page")
        case .checking: String(localized: "Checking the event, date and card", comment: "Sports Research live step: the server checks what the model found")
        case .writing: String(localized: "Writing to Plex", comment: "Sports Research live step: writing the title and poster into Plex")
        }
    }

    package static func stepSymbol(_ kind: SportsLiveStep.Kind) -> String {
        switch kind {
        case .thinking: "brain"
        case .searching: "magnifyingglass"
        case .reading: "doc.text.magnifyingglass"
        case .checking: "checkmark.seal"
        case .writing: "square.and.arrow.down"
        }
    }

    package static var event: String { String(localized: "Event", comment: "Sports Research detail: the event a file holds") }
    package static var date: String { String(localized: "Date", comment: "Sports Research detail: the day of the event") }
    package static var venue: String { String(localized: "Venue", comment: "Sports Research detail: where the event took place") }
    package static var card: String {
        String(localized: "sports.detail.card", defaultValue: "Card", comment: "Sports Research detail: heading above the bouts or matches on this part of the event, as in a fight card")
    }
    package static var sources: String { String(localized: "Sources", comment: "Sports Research detail: the websites the facts came from") }
    package static var research: String { String(localized: "Research", comment: "Sports Research detail: what the research took") }
    package static var time: String { String(localized: "Time", comment: "Sports Research detail: how long the research took") }
    package static var searches: String { String(localized: "Searches", comment: "Sports Research detail: how many web searches the research made") }
    package static var pagesRead: String { String(localized: "Pages read", comment: "Sports Research detail: how many web pages the research read") }
    package static var reused: String {
        String(localized: "Reused the research of another part of this event.", comment: "Sports Research detail: this file took no research of its own")
    }
    package static var redoQuestion: String {
        String(localized: "Crucible Server researches this file again and writes what it finds. Anything you changed in Plex by hand stays.", comment: "Sports Research: confirm researching a file again")
    }
    package static var file: String { String(localized: "File", comment: "Sports Research detail: the file's own name") }

    package static var unreachableTitle: String { String(localized: "Can\u{2019}t reach your Crucible Server", comment: "Sports Research: the server stopped answering") }
    package static var unreachableBody: String {
        String(localized: "Showing the last results it sent. Check that the computer with Plex is on.", comment: "Sports Research: what the screen shows while the server does not answer")
    }

    package static func becomes(_ file: String, _ title: String) -> String {
        String(localized: "\(file), now \(title)", comment: "Sports Research: a file's old name and its new title, read by VoiceOver")
    }

    /// "1m 12s" in the reader's language: hours and minutes past an hour, minutes and seconds past a minute.
    package static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        #if canImport(Darwin)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
        #else
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : seconds >= 60 ? [.minutes, .seconds] : [.seconds]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .narrow))
        #endif
    }

    /// "14 Nov 2026" in the reader's language, for the event's day.
    package static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
