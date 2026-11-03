import Foundation
import Testing
@testable import CrucibleCore

@Suite(.serialized)
struct PostPlayTests {
    private typealias JSON = [String: Any]

    private func request(_ key: String, type: String, show: String? = nil, queue: PlaybackQueue? = nil, offline: Bool = false) -> PlaybackRequest {
        PlaybackRequest(
            ratingKey: key,
            mediaType: type,
            showRatingKey: show,
            seasonRatingKey: nil,
            resumePosition: 0,
            metadata: PlaybackMetadata(title: "Ended", showName: show == nil ? nil : "The Show", seasonNumber: nil, episodeNumber: nil, posterPath: nil, duration: nil),
            offline: offline ? OfflinePlaybackSource(fileURL: URL(fileURLWithPath: "/tmp/x.mp4"), markers: [], durationSecs: 60) : nil,
            queue: queue
        )
    }

    private func withSetting(_ on: Bool?, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "postPlaySuggestions")
        defer { if let saved { defaults.set(saved, forKey: "postPlaySuggestions") } else { defaults.removeObject(forKey: "postPlaySuggestions") } }
        if let on { defaults.set(on, forKey: "postPlaySuggestions") } else { defaults.removeObject(forKey: "postPlaySuggestions") }
        try await body()
    }

    @Test func theSubjectIsTheMovieOrTheShowOfTheEpisode() throws {
        #expect(PostPlay.subjectKey(for: request("10", type: "movie")) == "10")
        #expect(PostPlay.subjectKey(for: request("11", type: "episode", show: "500")) == "500")
        #expect(PostPlay.subjectKey(for: request("11", type: "episode")) == nil)
        #expect(PostPlay.subjectKey(for: request("12", type: "clip")) == nil)
        #expect(PostPlay.subjectKey(for: request("10", type: "movie", offline: true)) == nil)
        let queue = try #require(PlaybackQueue(entries: [HomeFixtures.item("10")]))
        #expect(PostPlay.subjectKey(for: request("10", type: "movie", queue: queue)) == nil)
    }

    @Test func titlesStillToWatchComeFirstAndOnlyMoviesAndShowsAreOffered() {
        let items = [
            HomeFixtures.item("1", fields: ["viewCount": 2]),
            HomeFixtures.item("2"),
            HomeFixtures.item("3", type: "show", fields: ["leafCount": 10, "viewedLeafCount": 10]),
            HomeFixtures.item("4", type: "show", fields: ["leafCount": 10, "viewedLeafCount": 3]),
            HomeFixtures.item("5", type: "episode"),
            HomeFixtures.item("6", type: "show"),
            HomeFixtures.item("7"),
        ]
        #expect(PostPlay.ordered(items).map(\.id) == ["2", "4", "6", "7", "1", "3"])
        #expect(PostPlay.ordered(items, excluding: ["2", "6"]).map(\.id) == ["4", "7", "1", "3"])
        #expect(PostPlay.ordered(items, limit: 2).map(\.id) == ["2", "4"])
    }

    @Test func theHeadingNamesTheMovieOrTheShow() {
        #expect(PostPlay.heading(for: request("10", type: "movie")) == "Because You Watched Ended")
        #expect(PostPlay.heading(for: request("11", type: "episode", show: "500")) == "Because You Watched The Show")
        #expect(PostPlay.heading(after: nil) == "More Like This")
    }

    @Test func suggestionsComeFromTheRelatedTitlesOfTheShowAnEpisodeBelongsTo() async throws {
        let server = DetailStubServer()
        let related: [JSON] = [
            HomeFixtures.raw("500", type: "show"),
            HomeFixtures.raw("601", type: "show", fields: ["leafCount": 4, "viewedLeafCount": 4]),
            HomeFixtures.raw("602", type: "show"),
            HomeFixtures.raw("603"),
        ]
        let show: JSON = HomeFixtures.raw("500", type: "show", fields: ["Related": ["Hub": [["hubIdentifier": "show.similar", "Metadata": related]]]])
        server.reply(path: "/library/metadata/500", body: ["MediaContainer": ["size": 1, "Metadata": [show]]])
        try await withSetting(nil) {
            let suggestions = await PostPlay.suggestions(for: request("11", type: "episode", show: "500"), api: server.client)
            #expect(suggestions.map(\.id) == ["602", "603", "601"])
        }
        #expect(server.requests == ["/library/metadata/500"])
    }

    @Test func nothingIsAskedWhenTheSettingIsOffAndNothingIsOfferedWhenTheServerFails() async throws {
        let server = DetailStubServer()
        server.failTransport(path: "/library/metadata/10")
        try await withSetting(false) {
            #expect(await PostPlay.suggestions(for: request("10", type: "movie"), api: server.client).isEmpty)
        }
        #expect(server.requests.isEmpty)
        try await withSetting(true) {
            #expect(await PostPlay.suggestions(for: request("10", type: "movie"), api: server.client).isEmpty)
        }
        #expect(server.requests == ["/library/metadata/10"])
    }

    @Test func aServerThatDoesNotAnswerInTimeDoesNotHoldThePlayer() async throws {
        let silent = APIClient(baseURL: URL(string: "http://10.255.255.1:32400")!, token: "token")
        try await withSetting(true) {
            let started = ContinuousClock.now
            let suggestions = await PostPlay.suggestions(for: request("10", type: "movie"), api: silent, timeout: .milliseconds(300))
            #expect(suggestions.isEmpty)
            #expect(started.duration(to: .now) < .seconds(3))
        }
    }
}
