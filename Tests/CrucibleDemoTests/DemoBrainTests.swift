@testable import CrucibleCore
@testable import CrucibleDemo
import Foundation
import Testing

/// The demo's prepared answers, checked against the demo's own library: every example request of What to Watch gets
/// picks that are in the library in every language of the app, and every show the demo starts as watched gets a recap.
struct DemoBrainTests {
    private static let languages = ["en", "de", "fr", "es", "it", "pt-BR", "pl", "sv", "da", "nb", "fi", "is", "ko", "ja", "zh-Hans", "zh-Hant"].map(HostedBrain.languageName)

    private static func session(_ demo: DemoHarness, brain: DemoBrain, language: String) -> WatchSession {
        WatchSession(environment: WatchSession.Environment(
            loadLibrary: { try await WatchSession.library(api: demo.api) },
            ask: { alias, input async throws(HostedBrainError) in
                guard let reply = brain.reply(alias: alias, input: input, language: language) else { throw .unavailable }
                return reply
            },
            year: { 2026 }, hiddenLibraries: { [] }))
    }

    @Test func everyExampleGetsPicksFromTheLibraryInEveryLanguage() async throws {
        let answers = try #require(DemoAnswers.bundled(), "Data/answers.json is missing or unreadable")
        #expect(answers.watch.count == WatchCopy.examples.count)
        try await withDemo { demo in
            let library = try await WatchSession.library(api: demo.api)
            let held = Set(library.map(\.id))
            for language in Self.languages {
                for (place, example) in WatchCopy.examples.enumerated() {
                    #expect(answers.watch[place].answers[language] != nil, "example \(place) has no answer in \(language)")
                    let result = await Self.session(demo, brain: DemoBrain(answers: answers), language: language).answer(example) { _ in }
                    guard case .success(let answer) = result else {
                        Issue.record("\(language), \"\(example)\": \(result)")
                        continue
                    }
                    #expect(answer.picks.count >= 3, "\(language), \"\(example)\" has \(answer.picks.count) picks")
                    #expect(answer.picks.allSatisfy { held.contains($0.id) && $0.why.count >= 12 })
                    #expect(Set(answer.picks.map(\.id)).count == answer.picks.count)
                }
            }
        }
    }

    @Test func theFilmExampleKeepsToFilmsThePersonHasNotSeenUnderTwoHours() async throws {
        let answers = try #require(DemoAnswers.bundled())
        try await withDemo { demo in
            let result = await Self.session(demo, brain: DemoBrain(answers: answers), language: "English").answer(WatchCopy.examples[0]) { _ in }
            let picks = try #require(try? result.get().picks)
            #expect(picks.allSatisfy { $0.title.kind == .movie && $0.title.seen == .unseen && ($0.title.minutes ?? 0) <= 120 })
        }
    }

    @Test func aRequestOfThePersonsOwnHasNoPreparedAnswer() throws {
        let brain = DemoBrain(answers: try #require(DemoAnswers.bundled()))
        #expect(!brain.answers(alias: WatchPicker.planAlias, input: WatchPicker.planInput("a silent western", year: 2026), language: "English"))
        #expect(brain.answers(alias: WatchPicker.planAlias, input: WatchPicker.planInput(WatchCopy.examples[1], year: 2031), language: "Klingon"))
        #expect(!brain.answers(alias: DescribedRecap.alias, input: "Series: Nothing\nEpisodes they finished, oldest first:\n1. Nothing.", language: "English"))
        #expect(!DemoBrain(answers: nil).answers(alias: WatchPicker.planAlias, input: WatchPicker.planInput(WatchCopy.examples[0], year: 2026), language: "English"))
    }

    @Test func everyShowTheDemoStartsPartwayThroughHasARecapInEveryLanguage() async throws {
        let answers = try #require(DemoAnswers.bundled())
        let brain = DemoBrain(answers: answers)
        try await withDemo { demo in
            var written = 0
            for show in try await WatchSession.library(api: demo.api) where show.mediaType == "show" {
                let loaded = try await ShowDetailLoader.load(api: demo.api, showRatingKey: show.id, initialSeasonKey: nil, selectedSeasonKey: { nil }, onShow: { _ in })
                let model = try #require(loaded)
                let episodes = DescribedRecap.episodes(of: model)
                guard !episodes.isEmpty else { continue }
                let input = DescribedRecap.input(show: model.show.title, episodes: episodes)
                for language in Self.languages {
                    let reply = try #require(brain.reply(alias: DescribedRecap.alias, input: input, language: language), "\(model.show.title) has no recap in \(language)")
                    #expect(DescribedRecap.recap(from: reply) != nil, "\(model.show.title) in \(language): \(reply)")
                }
                written += 1
            }
            #expect(written >= 1)
        }
    }

    /// Writes what `tools/ai/gen_demo_answers.py` sends for the demo library to the file named in
    /// `CRUCIBLE_DEMO_ASKS`: every title as its digest fields, the recap message of every show with finished
    /// episodes, and the English name of each language.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CRUCIBLE_DEMO_ASKS"] != nil))
    func writeTheAsksTheGeneratorSends() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CRUCIBLE_DEMO_ASKS"])
        try await withDemo { demo in
            let library = try await WatchSession.library(api: demo.api)
            let titles: [[String: Any]] = library.compactMap(WatchTitle.init).map { title in
                [
                    "id": title.id, "kind": title.kind.rawValue, "title": title.title, "year": title.year as Any? ?? NSNull(), "minutes": title.minutes as Any? ?? NSNull(),
                    "seen": title.seen.rawValue, "rated": title.contentRating as Any? ?? NSNull(), "adult": WatchPicker.isForAdults(title.contentRating),
                    "digest": String(WatchPicker.digestLine(title, number: 0).dropFirst(2)),
                ]
            }
            var recaps: [[String: Any]] = []
            for show in library where show.mediaType == "show" {
                guard let model = try await ShowDetailLoader.load(api: demo.api, showRatingKey: show.id, initialSeasonKey: nil, selectedSeasonKey: { nil }, onShow: { _ in }) else { continue }
                let episodes = DescribedRecap.episodes(of: model)
                guard !episodes.isEmpty else { continue }
                recaps.append(["show": model.show.title, "episodes": episodes.map(\.code), "input": DescribedRecap.input(show: model.show.title, episodes: episodes)])
            }
            let asks: [String: Any] = ["titles": titles, "recaps": recaps, "languages": Self.languages, "budget": WatchPicker.inputBudget]
            try JSONSerialization.data(withJSONObject: asks, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
