import XCTest

/// Sports Research on the iPhone, shown from reports like the ones Crucible Server sends: setting up with two steps open,
/// researching with results, and without Crucible Pro. Each screen is captured from top to bottom, and a result's detail
/// sheet once, for review.
@MainActor
final class SportsResearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Writes `report` with its NOW-n times made real, and opens Sports Research on it.
    private func open(_ report: String, named name: String, pro: Bool = true, arguments: [String] = []) -> XCUIApplication {
        let now = Int(Date().timeIntervalSince1970)
        let resolved = report.components(separatedBy: "NOW-").enumerated().map { index, part -> String in
            guard index > 0 else { return part }
            let digits = part.prefix { $0.isNumber }
            return String(now - (Int(digits) ?? 0)) + part.dropFirst(digits.count)
        }.joined()
        let path = "/tmp/crucible-sports-\(name).json"
        FileManager.default.createFile(atPath: path, contents: Data(resolved.utf8))
        var environment = ["CRUCIBLE_OPEN": "sports", "CRUCIBLE_SPORTS_FIXTURE": path]
        if pro { environment["CRUCIBLE_PRO"] = "lifetime" }
        let app = IOSTest.launch(extraEnvironment: environment, arguments: arguments)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        for _ in 0..<3 where dontAllow.waitForExistence(timeout: 5) {
            if dontAllow.isHittable { dontAllow.tap() }
            IOSTest.settle(1)
        }
        XCTAssertTrue(IOSTest.element(app, "settings.sports.pill").waitForExistence(timeout: 60), "Sports Research never opened")
        IOSTest.settle(2.5)
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
        for page in 2...8 {
            if end.exists && end.isHittable { break }
            list.swipeUp(velocity: .slow)
            IOSTest.settle(1)
            IOSTest.capture("\(prefix)-\(page)", in: self)
            look()
        }
        XCTAssertTrue(end.exists, "\(last) never appeared")
        return seen
    }

    func testSettingUpLeadsWithTheStepsLeft() {
        let app = open(Self.setup, named: "setup")
        let expected = ["settings.sports.hero", "settings.sports.step.1", "settings.sports.step.3", "settings.sports.step.4"]
        let seen = captureTopToBottom(app, "setup", until: "settings.sports.step.4", expecting: expected)
        XCTAssertEqual(seen, Set(expected))
        IOSTest.element(app, "settings.sports.step.4").tap()
        IOSTest.settle(1.5)
        IOSTest.capture("setup-step4", in: self)
    }

    func testResearchingShowsTheLiveCardTheResultsAndADetail() {
        let app = open(Self.running, named: "running")
        let expected = ["settings.sports.live", "settings.sports.item.21418", "settings.sports.item.21417", "settings.sports.takeBack.9"]
        let seen = captureTopToBottom(app, "running", until: "settings.sports.lookNow", expecting: expected)
        XCTAssertEqual(seen, Set(expected))
        let result = IOSTest.element(app, "settings.sports.item.21417")
        for _ in 0..<6 where !result.isHittable { IOSTest.element(app, "settings.sports").swipeDown(velocity: .slow) }
        result.tap()
        XCTAssertTrue(IOSTest.element(app, "settings.sports.item").waitForExistence(timeout: 10), "the detail sheet never opened")
        IOSTest.settle(1.5)
        IOSTest.capture("detail-medium", in: self)
        app.swipeUp(velocity: .slow)
        IOSTest.settle(1)
        IOSTest.capture("detail-large", in: self)
    }

    func testLargeTypeKeepsEveryCardReadable() {
        let app = open(Self.running, named: "large", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        captureTopToBottom(app, "large", until: "settings.sports.item.21420")
    }

    func testWithoutProItShowsAnExampleAndTheWayToPro() {
        let app = open(Self.setup, named: "free", pro: false)
        XCTAssertTrue(IOSTest.element(app, "settings.sports.hero").exists)
        XCTAssertFalse(IOSTest.element(app, "settings.sports.step.1").exists, "setup shows without Pro")
        XCTAssertTrue(IOSTest.element(app, "settings.sports.how.0").exists, "how it works is missing without Pro")
        app.swipeUp(velocity: .slow)
        IOSTest.settle(1)
        XCTAssertTrue(IOSTest.element(app, "settings.sports.need.1").waitForExistence(timeout: 5), "what it needs is missing without Pro")
        IOSTest.capture("free-2", in: self)
        IOSTest.capture("free-1", in: self)
    }

    private static let setup = #"""
{"owner": true, "ready": false, "checks": [{"id": "owner", "group": "plex", "state": "done", "detail": "Signed in as guitaripod, who may edit the library.", "fix": null}, {"id": "model", "group": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf on 127.0.0.1.", "fix": null}, {"id": "tools", "group": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf calls tools on its own.", "fix": null}, {"id": "thinking", "group": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf thinks before it answers.", "fix": null}, {"id": "context", "group": "model", "state": "done", "detail": "256K tokens, room for several pages.", "fix": null}, {"id": "search", "group": "web", "state": "missing", "detail": "SearXNG at http://127.0.0.1:8888 is set, and is tried once you agree to where searches go.", "fix": "Agree in Crucible, or on the server: crucible-server sports --agree"}, {"id": "agreement", "group": "web", "state": "missing", "detail": "Searches go to your SearXNG.", "fix": "Agree in Crucible, or on the server: crucible-server sports --agree"}, {"id": "libraries", "group": "library", "state": "missing", "detail": "No library is chosen.", "fix": "Choose an Other Videos library in Crucible, or on the server: crucible-server sports --library <name>"}, {"id": "on", "group": "library", "state": "missing", "detail": "Research is off.", "fix": "Turn it on in Crucible, or on the server: crucible-server sports --on"}], "settings": {"on": false, "engine": "SearXNG at http://127.0.0.1:8888", "destination": "your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use", "agreed": false}, "libraries": [{"key": "4", "title": "Sports", "chosen": false, "kind": "sports"}, {"key": "3", "title": "Holy Grail", "chosen": false, "kind": "sports"}, {"key": "7", "title": "Game Cinematics", "chosen": false, "kind": "sports"}], "status": {"phase": "waiting", "current": null, "queued": 0, "lastPass": null, "lastError": null}, "counts": {}, "items": [], "model": {"name": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf", "host": "127.0.0.1"}}
"""#

    private static let running = #"""
{"owner": true, "ready": true, "checks": [{"id": "owner", "group": "plex", "state": "done", "detail": "Signed in as guitaripod, who may edit the library.", "fix": null}, {"id": "model", "group": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf on 127.0.0.1.", "fix": null}, {"id": "tools", "group": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf calls tools on its own.", "fix": null}, {"id": "thinking", "group": "model", "state": "done", "detail": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf thinks before it answers.", "fix": null}, {"id": "context", "group": "model", "state": "done", "detail": "256K tokens, room for several pages.", "fix": null}, {"id": "search", "group": "web", "state": "done", "detail": "SearXNG at http://127.0.0.1:8888 answers.", "fix": null}, {"id": "agreement", "group": "web", "state": "done", "detail": "Searches go to your SearXNG.", "fix": null}, {"id": "libraries", "group": "library", "state": "done", "detail": "Sports", "fix": null}, {"id": "on", "group": "library", "state": "done", "detail": "Research runs as new files arrive.", "fix": null}], "settings": {"on": true, "engine": "SearXNG at http://127.0.0.1:8888", "destination": "your SearXNG at http://127.0.0.1:8888, which asks the search engines it is set to use", "agreed": true}, "libraries": [{"key": "4", "title": "Sports", "chosen": true, "kind": "sports"}, {"key": "3", "title": "Holy Grail", "chosen": false, "kind": "sports"}, {"key": "7", "title": "Game Cinematics", "chosen": false, "kind": "sports"}, {"key": "9", "title": "Holy Grail", "chosen": false, "kind": "adult", "researched": 8}], "status": {"phase": "researching", "current": {"ratingKey": "21421", "name": "UFC Fight Night 293 Cortes-Acosta vs Walker Prelims", "file": "UFC Fight Night 293 Cortes-Acosta vs Walker Prelims 1080p WEB-DL H264 Fight-BB.mp4", "step": "Reading en.wikipedia.org", "started": NOW-41, "elapsed": 41, "steps": [{"id": 101, "kind": "thinking", "detail": "", "at": NOW-40}, {"id": 102, "kind": "searching", "detail": "UFC Fight Night 293 prelims", "at": NOW-36}, {"id": 103, "kind": "thinking", "detail": "", "at": NOW-30}, {"id": 104, "kind": "reading", "detail": "ufc.com/event/ufc-fight-night-november-07-2026", "at": NOW-22}, {"id": 105, "kind": "reading", "detail": "en.wikipedia.org/wiki/UFC_Fight_Night:_Cortes-Acosta_vs._Walker", "at": NOW-9}]}, "queued": 3, "lastPass": NOW-600, "lastError": null}, "counts": {"matched": 41, "attention": 1, "edited": 1}, "items": [{"ratingKey": "21418", "section": "4", "kind": "sports", "file": "/mnt/stuff2/Sports/Samourai.MMA.21.UFC.Fight.Pass.1080p.WEBRip.H264-Star.mp4", "fileName": "Samourai.MMA.21.UFC.Fight.Pass.1080p.WEBRip.H264-Star.mp4", "state": "attention", "title": "Samourai MMA 21", "note": "The model could not identify it: no page confirms the event's date.", "tries": 0, "nextTry": 0, "updated": NOW-900, "seconds": 0, "searches": 0, "reads": 0, "detail": null}, {"ratingKey": "21420", "section": "4", "kind": "sports", "file": "/mnt/stuff2/Sports/UFC.334.PPV.Ciryl.Gane.vs.Josh.Hokit.1080p.HDTV.h264-Star.mp4", "fileName": "UFC.334.PPV.Ciryl.Gane.vs.Josh.Hokit.1080p.HDTV.h264-Star.mp4", "state": "matched", "title": "UFC 334: Gane vs. Hokit", "note": "", "tries": 0, "nextTry": 0, "updated": NOW-30, "seconds": 16, "searches": 1, "reads": 1, "detail": {"event": "UFC 334: Gane vs. Hokit", "part": "Main card", "date": "2026-11-14", "venue": "Madison Square Garden", "city": "New York City, United States", "headline": "Gane vs. Hokit", "league": "UFC", "sport": "Mixed Martial Arts", "summary": "Ciryl Gane meets Josh Hokit for the heavyweight title at Madison Square Garden, with Kayla Harrison and Amanda Nunes in the co-main event.", "lineup": [{"matchup": "Ciryl Gane vs. Josh Hokit", "detail": "Heavyweight title"}, {"matchup": "Kayla Harrison vs. Amanda Nunes", "detail": "Women's Bantamweight title"}, {"matchup": "Jailton Almeida vs. Alexander Volkov", "detail": "Heavyweight"}], "sources": ["ufc.com", "en.wikipedia.org"], "posterUrl": "https://ufc.com/images/ufc-334-EVENT-ART.jpg"}}, {"ratingKey": "21417", "section": "4", "kind": "sports", "file": "/mnt/stuff2/Sports/UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4", "fileName": "UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4", "state": "matched", "title": "UFC 334: Gane vs. Hokit · Prelims", "note": "", "tries": 0, "nextTry": 0, "updated": NOW-60, "seconds": 0, "searches": 0, "reads": 0, "detail": {"event": "UFC 334: Gane vs. Hokit", "part": "Prelims", "date": "2026-11-14", "venue": "Madison Square Garden", "city": "New York City, United States", "headline": "Gane vs. Hokit", "league": "UFC", "sport": "Mixed Martial Arts", "summary": "Ciryl Gane meets Josh Hokit for the heavyweight title at Madison Square Garden, with Kayla Harrison and Amanda Nunes in the co-main event.", "lineup": [{"matchup": "Stephen Thompson vs. Charles Radtke", "detail": "Welterweight"}, {"matchup": "Drew Dober vs. Chris Duncan", "detail": "Lightweight"}], "sources": ["ufc.com", "en.wikipedia.org"], "posterUrl": "https://ufc.com/images/ufc-334-EVENT-ART.jpg"}}, {"ratingKey": "21416", "section": "4", "kind": "sports", "file": "/mnt/stuff2/Sports/UFC 334 Early Prelims 1080p WEB-DL H264-FBB.mp4", "fileName": "UFC 334 Early Prelims 1080p WEB-DL H264-FBB.mp4", "state": "matched", "title": "UFC 334: Gane vs. Hokit · Early prelims", "note": "", "tries": 0, "nextTry": 0, "updated": NOW-120, "seconds": 0, "searches": 0, "reads": 0, "detail": {"event": "UFC 334: Gane vs. Hokit", "part": "Early prelims", "date": "2026-11-14", "venue": "Madison Square Garden", "city": "New York City, United States", "headline": "Gane vs. Hokit", "league": "UFC", "sport": "Mixed Martial Arts", "summary": "Ciryl Gane meets Josh Hokit for the heavyweight title at Madison Square Garden, with Kayla Harrison and Amanda Nunes in the co-main event.", "lineup": [{"matchup": "Donte Johnson vs. Cesar Almeida", "detail": "Catchweight"}], "sources": ["ufc.com", "en.wikipedia.org"], "posterUrl": "https://ufc.com/images/ufc-334-EVENT-ART.jpg"}}, {"ratingKey": "21406", "section": "4", "kind": "sports", "file": "/mnt/stuff2/Sports/ufc.fight.night.286.nurmagomedov.vs.song.1080p.web.h264-verum.mkv", "fileName": "ufc.fight.night.286.nurmagomedov.vs.song.1080p.web.h264-verum.mkv", "state": "matched", "title": "UFC Fight Night 286: Nurmagomedov vs. Song", "note": "", "tries": 0, "nextTry": 0, "updated": NOW-400, "seconds": 18, "searches": 1, "reads": 2, "detail": {"event": "UFC Fight Night 286: Nurmagomedov vs. Song", "part": "Main card", "date": "2026-08-29", "venue": "SPD Bank Oriental Sports Center", "city": "Shanghai, China", "headline": "Nurmagomedov vs. Song", "league": "UFC", "sport": "Mixed Martial Arts", "summary": "", "lineup": [{"matchup": "Umar Nurmagomedov vs. Song Yadong", "detail": "Bantamweight"}], "sources": ["ufc.com", "en.wikipedia.org"], "posterUrl": null}}, {"ratingKey": "21411", "section": "4", "kind": "sports", "file": "/mnt/stuff2/Sports/ufc.332.silva.vs.wang.1080p.web.h264-verum.mkv", "fileName": "ufc.332.silva.vs.wang.1080p.web.h264-verum.mkv", "state": "matched", "title": "UFC 332: Silva vs. Wang", "note": "", "tries": 0, "nextTry": 0, "updated": NOW-500, "seconds": 26, "searches": 1, "reads": 2, "detail": {"event": "UFC 332: Silva vs. Wang", "part": "Main card", "date": "2026-10-03", "venue": "Delta Center", "city": "Salt Lake City, United States", "headline": "Silva vs. Wang", "league": "UFC", "sport": "Mixed Martial Arts", "summary": "", "lineup": [], "sources": ["ufc.com"], "posterUrl": null}}, {"ratingKey": "21300", "section": "4", "kind": "sports", "file": "/mnt/stuff2/Sports/UFC.229.720p.HDTV.x264-VERUM.mkv", "fileName": "UFC.229.720p.HDTV.x264-VERUM.mkv", "state": "edited", "title": "UFC 229: Khabib vs. McGregor", "note": "You changed this in Plex, so it is left as you made it.", "tries": 0, "nextTry": 0, "updated": NOW-3000, "seconds": 0, "searches": 0, "reads": 0, "detail": null}], "model": {"name": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf", "host": "127.0.0.1"}}
"""#
}
