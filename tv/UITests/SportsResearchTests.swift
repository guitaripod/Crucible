import XCTest

/// Sports Research on Apple TV, from a report like the one Crucible Server sends while two requirements are open: the pitch
/// beside the list, and each requirement's explanation in the context column once the focus reaches it.
@MainActor
final class SportsResearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func focusedID(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.identifier
    }

    func testEachRequirementExplainsItselfWhenFocused() {
        let path = "/tmp/crucible-sports-tv.json"
        FileManager.default.createFile(atPath: path, contents: Data(Self.setup.utf8))
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_OPEN": "sports", "CRUCIBLE_SPORTS_FIXTURE": path])
        let summary = app.descendants(matching: .any).matching(identifier: "sports.summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 120), "Sports Research never opened")
        TVTest.settle(2)
        TVTest.capture("sports-1-pitch", in: self)
        var reached: [String] = []
        for step in 1...18 where !reached.contains("sports.agreement") {
            TVTest.remote.press(.down)
            TVTest.settle(0.9)
            let id = focusedID(app)
            reached.append(id)
            if ["sports.check.search", "sports.check.agreement", "sports.on", "sports.agreement"].contains(id) {
                TVTest.capture("sports-\(step + 1)-\(id.replacingOccurrences(of: ".", with: "-"))", in: self)
            }
        }
        XCTAssertTrue(reached.contains("sports.check.agreement"), "the focus never reached the agreement, it went \(reached)")
        XCTAssertTrue(reached.contains("sports.agreement"), "the owner's agreement row never took the focus, it went \(reached)")
    }

    private static let setup = #"""
{"owner": true, "ready": false, "checks": [{"id": "owner", "state": "done", "detail": "Signed in as guitaripod, who may edit the library.", "fix": null}, {"id": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf on 127.0.0.1.", "fix": null}, {"id": "tools", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf calls tools on its own.", "fix": null}, {"id": "thinking", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf thinks before it answers.", "fix": null}, {"id": "context", "state": "done", "detail": "256K tokens, room for several pages.", "fix": null}, {"id": "search", "state": "missing", "detail": "SearXNG at http://127.0.0.1:8888 is set, and is tried once you agree to where searches go.", "fix": "Agree in Crucible, or on the server: crucible-server sports --agree"}, {"id": "agreement", "state": "missing", "detail": "Searches naming your sports files' events go to your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use, and public pages are read from this server.", "fix": "Agree in Crucible, or on the server: crucible-server sports --agree"}, {"id": "libraries", "state": "done", "detail": "Sports", "fix": null}, {"id": "on", "state": "missing", "detail": "Research is off.", "fix": "Turn it on in Crucible, or on the server: crucible-server sports --on"}], "settings": {"on": false, "engine": "SearXNG at http://127.0.0.1:8888", "destination": "your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use", "agreed": false}, "libraries": [{"key": "4", "title": "Sports", "chosen": true}, {"key": "3", "title": "Holy Grail", "chosen": false}, {"key": "7", "title": "Game Cinematics", "chosen": false}], "status": {"phase": "waiting", "current": null, "queued": 0, "lastPass": null, "lastError": null}, "counts": {}, "items": []}
"""#
}
