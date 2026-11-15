import XCTest

/// Sports Research on the iPhone, shown from a report like the one Crucible Server sends: setting it up with two requirements left,
/// and researching with results. Each screen is captured from top to bottom for review.
@MainActor
final class SportsResearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func open(_ report: String, named name: String) -> XCUIApplication {
        let path = "/tmp/crucible-sports-\(name).json"
        FileManager.default.createFile(atPath: path, contents: Data(report.utf8))
        let app = IOSTest.launch(extraEnvironment: ["CRUCIBLE_OPEN": "sports", "CRUCIBLE_SPORTS_FIXTURE": path])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        for _ in 0..<3 where dontAllow.waitForExistence(timeout: 5) {
            if dontAllow.isHittable { dontAllow.tap() }
            IOSTest.settle(1)
        }
        XCTAssertTrue(IOSTest.element(app, "settings.sports.summary").waitForExistence(timeout: 60), "Sports Research never opened")
        IOSTest.settle(2)
        return app
    }

    /// Captures the screen page by page from the top until `last` shows, and returns which of `expected` showed on the way.
    @discardableResult
    private func captureTopToBottom(_ app: XCUIApplication, _ prefix: String, until last: String, expecting expected: [String] = []) -> Set<String> {
        let list = IOSTest.element(app, "settings.sports")
        let end = IOSTest.element(app, last)
        var seen = Set<String>()
        let look = { for id in expected where IOSTest.element(app, id).exists { seen.insert(id) } }
        IOSTest.capture("\(prefix)-1", in: self)
        look()
        for page in 2...7 {
            if end.exists && end.isHittable { break }
            list.swipeUp(velocity: .slow)
            IOSTest.settle(1)
            IOSTest.capture("\(prefix)-\(page)", in: self)
            look()
        }
        XCTAssertTrue(end.exists, "\(last) never appeared")
        return seen
    }

    func testSettingUpShowsWhatIsLeftAndTheOwnersChoices() {
        let app = open(Self.setup, named: "setup")
        let expected = ["settings.sports.check.owner", "settings.sports.check.agreement", "settings.sports.check.on", "settings.sports.library.4", "settings.sports.agreement"]
        let seen = captureTopToBottom(app, "setup", until: "settings.sports.lookNow", expecting: expected)
        XCTAssertEqual(seen, Set(expected))
    }

    func testResearchingShowsTheFileTheStepAndTheResults() {
        let lastPass = Int(Date().timeIntervalSince1970) - 600
        let app = open(Self.running.replacingOccurrences(of: "LAST_PASS", with: String(lastPass)), named: "running")
        let expected = ["settings.sports.now", "settings.sports.item.21418", "settings.sports.item.21417"]
        let seen = captureTopToBottom(app, "running", until: "settings.sports.item.21300", expecting: expected)
        XCTAssertEqual(seen, Set(expected))
    }

    private static let setup = #"""
{"owner": true, "ready": false, "checks": [{"id": "owner", "state": "done", "detail": "Signed in as guitaripod, who may edit the library.", "fix": null}, {"id": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf on 127.0.0.1.", "fix": null}, {"id": "tools", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf calls tools on its own.", "fix": null}, {"id": "thinking", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf thinks before it answers.", "fix": null}, {"id": "context", "state": "done", "detail": "256K tokens, room for several pages.", "fix": null}, {"id": "search", "state": "missing", "detail": "SearXNG at http://127.0.0.1:8888 is set, and is tried once you agree to where searches go.", "fix": "Agree in Crucible, or on the server: crucible-server sports --agree"}, {"id": "agreement", "state": "missing", "detail": "Searches naming your sports files' events go to your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use, and public pages are read from this server.", "fix": "Agree in Crucible, or on the server: crucible-server sports --agree"}, {"id": "libraries", "state": "done", "detail": "Sports", "fix": null}, {"id": "on", "state": "missing", "detail": "Research is off.", "fix": "Turn it on in Crucible, or on the server: crucible-server sports --on"}], "settings": {"on": false, "engine": "SearXNG at http://127.0.0.1:8888", "destination": "your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use", "agreed": false}, "libraries": [{"key": "4", "title": "Sports", "chosen": true}, {"key": "3", "title": "Holy Grail", "chosen": false}, {"key": "7", "title": "Game Cinematics", "chosen": false}], "status": {"phase": "waiting", "current": null, "queued": 0, "lastPass": null, "lastError": null}, "counts": {}, "items": []}
"""#

    private static let running = #"""
{"owner": true, "ready": true, "checks": [{"id": "owner", "state": "done", "detail": "Signed in as guitaripod, who may edit the library.", "fix": null}, {"id": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf on 127.0.0.1.", "fix": null}, {"id": "tools", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf calls tools on its own.", "fix": null}, {"id": "thinking", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf thinks before it answers.", "fix": null}, {"id": "context", "state": "done", "detail": "256K tokens, room for several pages.", "fix": null}, {"id": "search", "state": "done", "detail": "SearXNG at http://127.0.0.1:8888 answers.", "fix": null}, {"id": "agreement", "state": "done", "detail": "Searches and page reads go to your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use.", "fix": null}, {"id": "libraries", "state": "done", "detail": "Sports", "fix": null}, {"id": "on", "state": "done", "detail": "Research runs as new files arrive.", "fix": null}], "settings": {"on": true, "engine": "SearXNG at http://127.0.0.1:8888", "destination": "your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use", "agreed": true}, "libraries": [{"key": "4", "title": "Sports", "chosen": true}, {"key": "3", "title": "Holy Grail", "chosen": false}, {"key": "7", "title": "Game Cinematics", "chosen": false}], "status": {"phase": "researching", "current": {"ratingKey": "21421", "name": "UFC Fight Night 293 Cortes-Acosta vs Walker", "step": "Reading ufc.com/event/ufc-fight-night-november-07-2026", "started": 0}, "queued": 3, "lastPass": LAST_PASS, "lastError": null}, "counts": {"matched": 41, "attention": 1, "edited": 1}, "items": [{"ratingKey": "21418", "section": "4", "file": "/mnt/stuff2/Sports/Samourai.MMA.21.UFC.Fight.Pass.1080p.WEBRip.H264-Star.mp4", "state": "attention", "title": "Samourai MMA 21", "note": "The model could not identify it: no page confirms the event's date.", "tries": 0, "nextTry": 0, "updated": 0}, {"ratingKey": "21417", "section": "4", "file": "/mnt/stuff2/Sports/UFC 334 Prelims 1080p WEB-DL H264-FBB/UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4", "state": "matched", "title": "UFC 334: Gane vs. Hokit · Prelims", "note": "", "tries": 0, "nextTry": 0, "updated": 0}, {"ratingKey": "21416", "section": "4", "file": "/mnt/stuff2/Sports/UFC 334 Early Prelims 1080p WEB-DL H264-FBB.mp4", "state": "matched", "title": "UFC 334: Gane vs. Hokit · Early prelims", "note": "", "tries": 0, "nextTry": 0, "updated": 0}, {"ratingKey": "21420", "section": "4", "file": "/mnt/stuff2/Sports/UFC.334.PPV.Ciryl.Gane.vs.Josh.Hokit.1080p.HDTV.h264-Star.mp4", "state": "matched", "title": "UFC 334: Gane vs. Hokit", "note": "", "tries": 0, "nextTry": 0, "updated": 0}, {"ratingKey": "21406", "section": "4", "file": "/mnt/stuff2/Sports/ufc.fight.night.286.nurmagomedov.vs.song.1080p.web.h264-verum.mkv", "state": "matched", "title": "UFC Fight Night 286: Nurmagomedov vs. Song", "note": "", "tries": 0, "nextTry": 0, "updated": 0}, {"ratingKey": "21411", "section": "4", "file": "/mnt/stuff2/Sports/ufc.332.silva.vs.wang.1080p.web.h264-verum.mkv", "state": "matched", "title": "UFC 332: Silva vs. Wang", "note": "", "tries": 0, "nextTry": 0, "updated": 0}, {"ratingKey": "21300", "section": "4", "file": "/mnt/stuff2/Sports/UFC.229.720p.HDTV.x264-VERUM.mkv", "state": "edited", "title": "UFC 229: Khabib vs. McGregor", "note": "You changed this in Plex, so it is left as you made it.", "tries": 0, "nextTry": 0, "updated": 0}]}
"""#
}
