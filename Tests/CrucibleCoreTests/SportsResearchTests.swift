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
        #expect(report.libraries == [SportsLibrary(key: "4", title: "Sports", chosen: true)])
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
    }
}
