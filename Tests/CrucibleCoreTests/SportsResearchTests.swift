import Foundation
import Testing
@testable import CrucibleCore

struct SportsResearchTests {
    private let json = """
    {"owner": true, "ready": false,
     "checks": [
       {"id": "on", "state": "missing", "detail": "Research is off.", "fix": "Turn it on in Crucible, or on the server: crucible-server sports --on"},
       {"id": "owner", "state": "done", "detail": "Signed in as guitaripod, who may edit the library.", "fix": null},
       {"id": "tools", "state": "done", "detail": "bolt calls tools on its own.", "fix": null},
       {"id": "model", "state": "done", "detail": "bolt on 127.0.0.1.", "fix": null},
       {"id": "search", "state": "failed", "detail": "the search engines brave are turning searches away for now", "fix": "Start the search engine"},
       {"id": "someday", "state": "pending", "detail": "A check from a newer server.", "fix": null}
     ],
     "settings": {"on": false, "engine": "SearXNG at http://127.0.0.1:8888", "destination": "your SearXNG at http://127.0.0.1:8888", "agreed": true},
     "libraries": [{"key": "4", "title": "Sports", "chosen": true}],
     "status": {"phase": "researching", "current": {"ratingKey": "21417", "name": "UFC 334 Prelims", "step": "Reading ufc.com/event/ufc-334", "started": 1794736125}, "queued": 3, "lastPass": 1794730000, "lastError": null},
     "counts": {"matched": 40, "attention": 2},
     "items": [
       {"ratingKey": "1", "section": "4", "file": "/s/a.mkv", "state": "matched", "title": "UFC 334: Gane vs. Hokit", "note": "", "tries": 0, "nextTry": 0, "updated": 300},
       {"ratingKey": "2", "section": "4", "file": "/s/Samourai.MMA.21.mkv", "state": "attention", "title": "Samourai MMA 21", "note": "The model could not identify it", "tries": 1, "nextTry": 0, "updated": 100},
       {"ratingKey": "3", "section": "4", "file": "C:\\\\Sports\\\\b.mkv", "state": "matched", "title": "UFC 333", "note": "", "tries": 0, "nextTry": 0, "updated": 200}
     ]}
    """

    private func board() throws -> SportsBoard {
        SportsBoard(report: try JSONDecoder().decode(SportsReport.self, from: Data(json.utf8)))
    }

    @Test func decodesWhatTheServerReports() throws {
        let report = try board().report
        #expect(report.owner && !report.ready)
        #expect(report.status.isWorking)
        #expect(report.status.current?.step == "Reading ufc.com/event/ufc-334")
        #expect(report.libraries == [SportsLibrary(key: "4", title: "Sports", chosen: true, holdsKinds: false)])
        #expect(!report.items.contains { $0.canTakeBack }, "a server from before Library Research cannot take research back")
        #expect(report.checks.first { $0.id == "someday" }?.state == .failed)
    }

    @Test func groupsRequirementsInTheOrderAPersonMeetsThem() throws {
        let groups = try board().groups
        #expect(groups.map(\.0) == [.plex, .model, .web, .library])
        #expect(groups[1].1.map(\.id) == ["model", "tools"])
        #expect(!groups.flatMap(\.1).contains { $0.id == "someday" })
    }

    @Test func countsWhatIsLeftAndPutsItemsNeedingALookFirst() throws {
        let board = try board()
        #expect(board.doneCount == 3 && board.total == 6)
        #expect(board.open.map(\.id) == ["search", "on"])
        #expect(!board.onlySwitchIsOff)
        #expect(board.items.map(\.ratingKey) == ["2", "1", "3"])
        #expect(board.items[2].fileName == "b.mkv")
        #expect(board.count("matched") == 40 && board.count("edited") == 0)
    }

    @Test func onlyTheSwitchLeftIsToldApart() {
        let checks = [SportsCheck(id: "model", state: .done, detail: ""), SportsCheck(id: "on", state: .missing, detail: "")]
        let report = SportsReport(owner: true, ready: false, checks: checks, settings: SportsSettings(on: false, agreed: true), libraries: [], status: SportsStatus(phase: "waiting"), counts: [:], items: [])
        #expect(SportsBoard(report: report).onlySwitchIsOff)
        #expect(!SportsStatus(phase: "idle").isWorking)
    }

    @Test func everyRequirementHasWordsAndOnlyTheAppSettlesItsOwnChoices() {
        for requirement in SportsRequirement.allCases {
            #expect(!SportsCopy.title(requirement).isEmpty)
            #expect(!SportsCopy.why(requirement).isEmpty)
        }
        #expect(SportsRequirement.allCases.filter(\.settledInApp) == [.agreement, .libraries, .on])
    }

    @Test func sportsResearchIsListedOnlyBesideACrucibleServer() {
        #expect(!ProFeature.listed(isTV: false, includingServer: false).contains(.sportsResearch))
        #expect(ProFeature.listed(isTV: true, includingServer: true).contains(.sportsResearch))
    }

    @Test func anOwnersChangeShowsBeforeTheServerConfirmsIt() throws {
        let report = try board().report.expecting(on: true, libraries: [], agree: false)
        #expect(report.settings.on && !report.settings.agreed)
        #expect(report.libraries.allSatisfy { !$0.chosen })
    }

    @Test func onlyACommandIsOfferedForCopying() {
        #expect(sportsCommand(in: "Turn it on in Crucible, or on the server: crucible-server sports --on") == "crucible-server sports --on")
        #expect(sportsCommand(in: "Start the model server at http://127.0.0.1:8080/v1.") == nil)
        #expect(sportsCommand(in: "On the server: crucible-server sports --searxng http://127.0.0.1:8888 (a SearXNG with its JSON format on), or --brave-key-file <file>") == "crucible-server sports --searxng http://127.0.0.1:8888")
        #expect(sportsCommand(in: "crucible-server model --context 65536 (and serve the model with that window)") == "crucible-server model --context 65536")
        #expect(sportsCommand(in: "On the server: crucible-server sports --on.") == "crucible-server sports --on")
    }

    @Test func anUnansweringServerIsNotCalledOld() {
        #expect(SportsCopy.failure(.unreachable, hasSports: nil) == CompanionError.unreachable.message)
        #expect(SportsCopy.failure(.wrongServer, hasSports: true) == CompanionError.wrongServer.message)
        #expect(SportsCopy.failure(.failed("404"), hasSports: false) == SportsCopy.updateServer)
    }

    @Test func agreeingIsAChoiceOnlyOnceASearchEngineIsSet() throws {
        var report = try board().report
        report.owner = true
        let agreement = SportsCheck(id: "agreement", state: .missing, detail: "Needs a search engine first.", fix: "Set a search engine first.")
        report.settings.destination = nil
        #expect(!agreement.settledInApp(in: report))
        report.settings.destination = "your SearXNG at http://127.0.0.1:8888"
        #expect(agreement.settledInApp(in: report))
        report.owner = false
        #expect(!agreement.settledInApp(in: report))
    }

    private let live = """
    {"owner": true, "ready": true, "checks": [{"id": "owner", "group": "plex", "state": "done", "detail": "", "fix": null}],
     "settings": {"on": true, "agreed": true}, "libraries": [],
     "status": {"phase": "researching", "queued": 0,
       "current": {"ratingKey": "9", "name": "UFC 334 Prelims", "file": "UFC 334 Prelims 1080p.mp4", "step": "", "started": 100, "elapsed": 41,
         "steps": [{"id": 1, "kind": "thinking", "at": 1}, {"id": 2, "kind": "searching", "detail": "UFC 334 prelims", "at": 2}, {"id": 3, "kind": "dreaming", "at": 3}]}},
     "counts": {"matched": 2},
     "items": [
       {"ratingKey": "1", "file": "/s/UFC.334.mkv", "state": "matched", "title": "UFC 334: Gane vs. Hokit", "updated": 300, "seconds": 23, "searches": 1, "reads": 2,
        "detail": {"event": "UFC 334: Gane vs. Hokit", "part": "Prelims", "date": "2026-11-14", "venue": "Madison Square Garden", "city": "New York City, United States", "headline": "Gane vs. Hokit", "summary": "", "lineup": [{"matchup": "Stephen Thompson vs. Charles Radtke", "detail": "Welterweight"}], "sources": ["ufc.com"]}},
       {"ratingKey": "2", "file": "/s/UFC.334.Early.mkv", "state": "matched", "title": "UFC 334 · Early prelims", "updated": 200, "seconds": 0, "searches": 0, "reads": 0},
       {"ratingKey": "3", "file": "/s/UFC.229.mkv", "state": "matched", "title": "UFC 229", "updated": 100, "seconds": null, "searches": null, "reads": null}
     ]}
    """

    private func liveBoard() throws -> SportsBoard {
        SportsBoard(report: try JSONDecoder().decode(SportsReport.self, from: Data(live.utf8)))
    }

    @Test func decodesTheLiveResearchNewestStepFirst() throws {
        let current = try #require(try liveBoard().report.status.current)
        #expect(current.file == "UFC 334 Prelims 1080p.mp4" && current.elapsed == 41)
        #expect(current.newestSteps(2).map(\.id) == [3, 2])
        #expect(current.steps.last?.kind == .thinking, "a step kind from a newer server reads as thinking")
        #expect(SportsCopy.step(current.steps[1]).contains("UFC 334 prelims"))
    }

    @Test func aResultCarriesItsEventAndWhatTheResearchTook() throws {
        let board = try liveBoard()
        let item = try #require(board.report.items.first { $0.ratingKey == "1" })
        let detail = try #require(item.detail)
        #expect(detail.place == "Madison Square Garden, New York City, United States")
        #expect(detail.day.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0).day } == 14)
        #expect(item.posterWords == SportsPosterWords(eyebrow: "UFC 334 · Prelims", caption: "Gane vs. Hokit"))
        #expect(item.posterPath == "/library/metadata/1/thumb")
        #expect(SportsCopy.meta(item).hasSuffix("Madison Square Garden, New York City, United States"))
        #expect(item.measured && !item.reusedResearch)
        #expect(board.hero?.ratingKey == "1", "the hero is the newest match that has its event")
    }

    @Test func onlyMeasuredEffortClaimsReusedResearch() throws {
        let items = try liveBoard().report.items
        #expect(items[1].measured && items[1].reusedResearch)
        #expect(!items[2].measured && !items[2].reusedResearch, "a file from before the counts is not said to reuse research")
        #expect(try !board().report.items[0].measured, "a server without the counts sends none")
    }

    @Test func posterWordsLeaveOutTheMainCard() {
        #expect(SportsPosterWords(event: "UFC 334: Gane vs. Hokit", part: "Main card", headline: "").eyebrow == "UFC 334")
        #expect(SportsPosterWords(event: "Samourai MMA 21", part: nil, headline: "Doe vs. Roe") == SportsPosterWords(eyebrow: "Samourai MMA 21", caption: "Doe vs. Roe"))
    }

    @Test func theScreenFollowsProOwnershipAndWhatIsLeft() throws {
        let setup = try board()
        #expect(setup.mode(isPro: false) == .notPro)
        #expect(setup.mode(isPro: true) == .setup)
        #expect(try liveBoard().mode(isPro: true) == .ready)
        var shared = setup.report
        shared.owner = false
        #expect(SportsBoard(report: shared).mode(isPro: true) == .viewer)
    }

    @Test func stepsAreNumberedAndTheFirstOpenOneLeads() throws {
        let steps = try board().steps
        #expect(steps.map(\.number) == [1, 2, 3, 4])
        #expect(steps.map(\.state) == [.done, .done, .failed, .missing])
        #expect(try board().firstOpenStep?.group == .web)
        #expect(SportsCopy.howSteps.count == 4)
    }

    @Test func aNeedsALookResultSaysWhyOrWhatToDo() {
        let noted = SportsItem(ratingKey: "2", file: "/s/x.mkv", state: "attention", title: "", note: "No page confirms the date.", updated: 1)
        #expect(SportsCopy.meta(noted) == "No page confirms the date.")
        #expect(SportsCopy.meta(SportsItem(ratingKey: "3", file: "/s/y.mkv", state: "attention", title: "", updated: 1)) == SportsCopy.attentionHelp)
        #expect(SportsItemLabel.title(noted) == "x.mkv")
    }

    @Test func filesThatWillBeTriedAgainCountAsNeedingALook() throws {
        var report = try board().report
        report.counts = ["matched": 40, "attention": 2, "failed": 3]
        let board = SportsBoard(report: report)
        #expect(board.needingALookCount == 5)
        #expect(SportsCopy.counts(board).contains("5"))
        report.counts = ["matched": 40]
        #expect(SportsBoard(report: report).needingALookCount == 1, "an older server's counts fall back to the items sent")
    }

    @Test func aSearchPauseSaysWhoAskedForItAndWhenResearchGoesOn() throws {
        let json = #"{"phase": "paused", "pausedUntil": 1794763800, "limited": ["Brave", "Google CSE", "Qwant"], "lastError": "Brave, Google CSE and Qwant are turning searches away for now", "queued": 0}"#
        let status = try JSONDecoder().decode(SportsStatus.self, from: Data(json.utf8))
        #expect(status.isPausedForSearch && !status.isWorking)
        #expect(status.limited == ["Brave", "Google CSE", "Qwant"])
        let line = SportsCopy.searchPaused(status)
        #expect(line.contains("Brave") && line.contains("Qwant") && line.contains("asked for a break"))
        let older = try JSONDecoder().decode(SportsStatus.self, from: Data(#"{"phase": "idle", "lastError": "busy"}"#.utf8))
        #expect(!older.isPausedForSearch && older.limited.isEmpty && older.pausedUntil == nil)
        #expect(SportsCopy.searchPaused(older) == "busy")
    }

    @Test func librariesSayWhatTheyHoldAndWhatResearchTouched() throws {
        let json = """
        {"owner": true, "ready": true, "checks": [], "settings": {"on": true, "agreed": true},
         "libraries": [{"key": "4", "title": "Sports", "chosen": true}, {"key": "3", "title": "Holy Grail", "chosen": false, "kind": "adult", "researched": 8}, {"key": "7", "title": "Game Cinematics", "chosen": true, "kind": "general", "researched": 2}],
         "status": {"phase": "idle", "undoing": 5}, "counts": {},
         "items": [
           {"ratingKey": "1", "section": "7", "kind": "general", "file": "/g/01 - Wings of Liberty - The Deal.mkv", "state": "matched", "title": "The Deal", "updated": 2, "seconds": 15, "searches": 2, "reads": 1,
            "detail": {"kind": "general", "event": "The Deal", "series": "StarCraft II: Wings of Liberty", "studio": "Blizzard Entertainment", "people": ["Neil Kaplan"], "date": "", "summary": "The opening cinematic.", "sources": ["behindthecinematic.com"]}},
           {"ratingKey": "2", "section": "3", "kind": "adult", "file": "/a/x.mp4", "state": "matched", "title": "Tempted To Touch", "updated": 3, "seconds": 10, "searches": 2, "reads": 3,
            "detail": {"kind": "adult", "event": "Tempted To Touch", "studio": "Reality Kings", "people": ["Rachel Starr"], "date": "2007-03-13"}},
           {"ratingKey": "3", "section": "4", "file": "/s/UFC 334 Prelims.mp4", "state": "undone", "title": "UFC 334 Prelims", "updated": 1}
         ]}
        """
        let board = SportsBoard(report: try JSONDecoder().decode(SportsReport.self, from: Data(json.utf8)))
        let libraries = board.report.libraries
        #expect(libraries.map(\.kind) == [.sports, .adult, .general])
        #expect(libraries.map(\.researched) == [0, 8, 2])
        #expect(libraries.map(\.holdsKinds) == [false, true, true])
        #expect(board.report.status.undoing == 5)
        let cinematic = try #require(board.report.items.first { $0.ratingKey == "1" })
        #expect(cinematic.kind == .general && cinematic.showsArtwork && cinematic.canTakeBack)
        #expect(cinematic.detail?.people == ["Neil Kaplan"] && cinematic.detail?.series == "StarCraft II: Wings of Liberty")
        #expect(cinematic.posterWords == SportsPosterWords(eyebrow: "Blizzard Entertainment", caption: "The Deal"))
        let adult = try #require(board.report.items.first { $0.ratingKey == "2" })
        #expect(!adult.showsArtwork && adult.canTakeBack)
        #expect(board.hero?.ratingKey == "1", "an adult video is never the hero")
        let undone = try #require(board.report.items.first { $0.ratingKey == "3" })
        #expect(!undone.canTakeBack && SportsCopy.itemState("undone") != SportsCopy.itemState("failed"))
        #expect(board.items.last?.ratingKey == "3", "taken-back files list last")
        let chosen = board.report.expecting(libraries: ["4", "3"], kinds: ["3": .adult]).libraries.first { $0.key == "3" }
        #expect(chosen?.chosen == true && chosen?.kind == .adult)
    }
}
