import XCTest

/// The base of the player's UI test classes: the items they play, a mock reset to plain playback around each test, and the helpers
/// that launch straight into the player and read the timeline reports the mock received.
@MainActor
class PlayerTestCase: TVTestCase {
    static let episode = "4013"
    static let nextEpisode = "4014"
    static let movie = "1001"
    static let endOfItemWait: TimeInterval = 180
    static let dismissalWait: TimeInterval = 45
    /// Direct play (Original quality), whatever an earlier test class left in the simulator's preferences: a transcode of the mock ignores the resume offset, so an item resumed near the end would not end.
    static let defaultQuality = "0"

    /// The previous test's app is ended first: left running, it keeps reporting its playhead and overwrites the progress the next test sets.
    override func setUp() {
        continueAfterFailure = false
        XCUIApplication().terminate()
        TVTest.configureMock()
        setFlags("clip_markers=0&no_credits=0&fail_parts=0&fail_transcode=0&fail_metadata_once=0&latency_ms=0&plex_timeline=0")
    }

    override func tearDown() {
        setFlags("clip_markers=0&no_credits=0&fail_parts=0&fail_transcode=0&fail_metadata_once=0&latency_ms=0&plex_timeline=0")
    }

    /// Launches straight into `ratingKey`'s player. The device's own resume points are hidden for the run: a point an earlier test's app
    /// saved but never got confirmed would be sent to the mock at launch, as it should be, and replace the progress this test set.
    func launch(playing ratingKey: String, arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments += arguments
        app.launchArguments += ["-playbackResumePoints", "<data></data>"]
        if !arguments.contains("-streamingQuality") {
            app.launchArguments += ["-streamingQuality", Self.defaultQuality]
        }
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        app.launchEnvironment["CRUCIBLE_OPEN_LINK"] = "crucible://play/\(ratingKey)"
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CRUCIBLE_") && key != "CRUCIBLE_OPEN_LINK" {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// Presses Left until the card's leave button has focus, so a press that the busy focus engine swallowed is repeated instead of Select landing on Play Now.
    func focusLeaveButton(_ leave: XCUIElement) -> Bool {
        for _ in 0..<4 {
            if leave.hasFocus { return true }
            TVTest.remote.press(.left)
            if TVTest.waitForFocus(leave, timeout: 4) { return true }
        }
        return leave.hasFocus
    }

    /// Waits for the Up Next card and for focus to settle on its Play Now button. The card shows up in the accessibility tree while it is still sliding in, about half a second before the focus engine moves focus onto it; a press sent in that gap goes to the player underneath and is lost, which tvOS 27 exposes because it lists the card a little earlier than tvOS 26 did.
    func waitForFocusedUpNextCard(in app: XCUIApplication, timeout: TimeInterval = 40) -> Bool {
        guard app.otherElements["player.upNext"].waitForExistence(timeout: timeout) else { return false }
        return TVTest.waitForFocus(app.buttons["player.upNext.play"])
    }

    func waitForPlayback(in app: XCUIApplication) -> Bool {
        app.otherElements["player.view"].waitForExistence(timeout: 60)
    }

    nonisolated func setFlags(_ query: String) {
        Mock.get("/mock/flags?\(query)")
    }

    /// Leaves `ratingKey` unwatched and stopped `seconds` in, as if the viewer had walked away there. An earlier test of the class may
    /// have finished it, and a watched title starts from the beginning whatever its offset says.
    nonisolated func setProgress(_ ratingKey: String, seconds: Int) {
        let ms = seconds * 1000
        Mock.get("/:/unscrobble?key=\(ratingKey)&identifier=com.plexapp.plugins.library")
        Mock.get("/:/timeline?ratingKey=\(ratingKey)&key=/library/metadata/\(ratingKey)&state=stopped&time=\(ms)&duration=2700000")
    }

    struct Report {
        let ratingKey: String
        let state: String
        let timeMs: Int
    }

    func waitForPlaying(otherThan ratingKey: String, since mark: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if timeline(since: mark).contains(where: { $0.ratingKey != ratingKey && $0.state == "playing" }) { return true }
            TVTest.settle(1)
        }
        return false
    }

    func timeline(since mark: Int) -> [Report] {
        Mock.log("/:/timeline").dropFirst(mark).compactMap { line in
            guard let components = URLComponents(string: "http://x" + line.dropFirst(4)),
                  let items = components.queryItems,
                  let key = items.first(where: { $0.name == "ratingKey" })?.value,
                  let state = items.first(where: { $0.name == "state" })?.value,
                  let timeMs = items.first(where: { $0.name == "time" })?.value.flatMap(Int.init) else { return nil }
            return Report(ratingKey: key, state: state, timeMs: timeMs)
        }
    }

    /// The Up Next card's line while it counts down, e.g. "S1 E14 · Playing in 5 s".
    static let countingDown = NSPredicate(format: "label CONTAINS 'Playing in'")

    func hasPlayed(_ ratingKey: String, since mark: Int) -> Bool {
        timeline(since: mark).contains { $0.ratingKey == ratingKey && $0.state == "playing" }
    }

    func timelineMark() -> Int {
        Mock.log("/:/timeline").count
    }

    func waitForReport(pastMs: Int, since mark: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if timeline(since: mark).contains(where: { $0.timeMs >= pastMs }) { return true }
            TVTest.settle(1)
        }
        return false
    }

    func waitForReport(_ ratingKey: String, state: String, since mark: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if timeline(since: mark).contains(where: { $0.ratingKey == ratingKey && $0.state == state }) { return true }
            TVTest.settle(1)
        }
        return false
    }
}

/// The mock server's control surface, called without blocking on a synchronous URL load (which the
/// system flags as a runtime issue when it happens on the main thread).
enum Mock {
    private final class Box: @unchecked Sendable {
        var data: Data?
    }

    static var base: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? "http://127.0.0.1:32467"
    }

    @discardableResult
    static func get(_ path: String) -> Data? {
        guard let url = URL(string: base + path) else { return nil }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            box.data = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return box.data
    }

    static func log(_ needle: String) -> [String] {
        let encoded = needle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? needle
        guard let data = get("/mock/log?q=\(encoded)"),
              let lines = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return lines
    }
}
