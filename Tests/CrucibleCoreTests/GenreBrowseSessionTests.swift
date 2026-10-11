import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct GenreBrowseSessionTests {
    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private static let genre = SearchGenre(title: "Drama", sources: [GenreSource(sectionId: "1", key: "5")])

    @MainActor
    private final class Recorder {
        private(set) var states: [GenreBrowseState] = []

        func record(_ state: GenreBrowseState) {
            states.append(state)
        }
    }

    private func session(
        _ handler: @escaping @Sendable (PlexEndpoint) async throws -> PlexMediaContainer
    ) -> (GenreBrowseSession, Recorder) {
        let session = GenreBrowseSession(genre: Self.genre, loader: SearchLoader(fetch: handler))
        let recorder = Recorder()
        session.onChange = { recorder.record($0) }
        return (session, recorder)
    }

    @Test func loadsTheTitlesSorted() async throws {
        let page = try SearchFixtures.page([try SearchFixtures.item("2", "movie", "B"), try SearchFixtures.item("1", "movie", "A")])
        let (session, recorder) = session { _ in page }
        session.load()
        #expect(recorder.states == [.loading])
        await waitUntil { recorder.states.count >= 2 }
        guard case .loaded(let items) = recorder.states.last else {
            Issue.record("expected loaded")
            return
        }
        #expect(items.map(\.title) == ["A", "B"])
        #expect(session.state == .loaded(items))
    }

    @Test func noTitlesIsEmpty() async throws {
        let page = try SearchFixtures.page([])
        let (session, recorder) = session { _ in page }
        session.load()
        await waitUntil { recorder.states.count >= 2 }
        #expect(recorder.states == [.loading, .empty])
    }

    @Test func aFailureCarriesTheMessageAndLoadAgainRecovers() async throws {
        let attempts = RequestLog()
        let page = try SearchFixtures.page([try SearchFixtures.item("1", "movie", "A")])
        let (session, recorder) = session { endpoint in
            await attempts.record(endpoint)
            if await attempts.count == 1 { throw Boom() }
            return page
        }
        session.load()
        await waitUntil { recorder.states.count >= 2 }
        #expect(recorder.states.last == .failed(message: "boom"))

        session.load()
        await waitUntil { recorder.states.count >= 4 }
        #expect(recorder.states.suffix(2).first == .loading)
        guard case .loaded = recorder.states.last else {
            Issue.record("expected loaded")
            return
        }
    }

    @Test func aCancelledRequestIsIgnored() async {
        let (session, recorder) = session { _ in throw URLError(.cancelled) }
        session.load()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.states == [.loading])
    }

    @Test func cancelDropsTheResult() async throws {
        let gate = Gate()
        let page = try SearchFixtures.page([try SearchFixtures.item("1", "movie", "A")])
        let (session, recorder) = session { _ in
            await gate.wait()
            return page
        }
        session.load()
        while !(await gate.hasWaiter) { try? await Task.sleep(for: .milliseconds(2)) }
        session.cancel()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(recorder.states == [.loading])
    }
}
