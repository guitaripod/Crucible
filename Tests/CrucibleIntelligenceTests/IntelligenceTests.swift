import Foundation
import FoundationModels
import Testing
@testable import CrucibleCore
@testable import CrucibleIntelligence

struct PlainSegmentTests {
    @Test func segmentsFollowSpoilersAndKeepTheirSpaces() async throws {
        let lines = TraktCommentText("Open **wide** [spoiler]the end[/spoiler] then more\n`code`").lines
        let segments = PlainSegments(lines)
        #expect(segments.segments.map(\.text) == ["Open wide", "the end", "then more"])
        #expect(segments.segments.map(\.isSpoiler) == [false, true, false])
        let translated = try await segments.translated { texts throws(TranslationFailure) in texts.map { $0.uppercased() } }
        #expect(TraktCommentText.markup(translated) == "OPEN WIDE [spoiler]THE END[/spoiler] THEN MORE\n`code`")
    }

    @Test func aTranslationThatLosesAPieceFails() async {
        let segments = PlainSegments(TraktCommentText("one [spoiler]two[/spoiler]").lines)
        await #expect(throws: TranslationFailure.failed) {
            try await segments.translated { _ throws(TranslationFailure) in ["only one"] }
        }
    }

    @Test func translationsStayOnTheirLine() {
        #expect(PlainSegments.oneLine("First part.\n\nSecond part.\n") == "First part. Second part.")
    }
}

struct LanguageDetectorTests {
    @Test func clearTextIsReadAndShortTextLeansOnTheHint() {
        #expect(LanguageDetector.language(of: "Me encantó la película, aunque la segunda mitad se hace larga.") == "es")
        #expect(LanguageDetector.language(of: "Tämä elokuva oli aivan mahtava, suosittelen kaikille.") == "fi")
        #expect(LanguageDetector.language(of: "This was a fantastic film and I would watch it again.", hint: "de") == "en")
        #expect(LanguageDetector.language(of: "10/10", hint: "en") == nil)
        #expect(LanguageDetector.language(of: "Top", hint: "de") == "de")
        #expect(LanguageDetector.language(of: "!!!") == nil)
        #expect(LanguageDetector.language(of: "这部电影非常好看，我很喜欢最后的结局。") == "zh-Hans")
    }

    @Test func textInTheTargetLanguageNeedsNoTranslation() {
        #expect(LanguageDetector.needsTranslation("This was a fantastic film and I would watch it again.", hint: nil, into: "en") == nil)
        #expect(LanguageDetector.needsTranslation("Me encantó la película, aunque la segunda mitad se hace larga.", hint: "en", into: "en") == "es")
        #expect(LanguageDetector.needsTranslation("This was a fantastic film and I would watch it again.", hint: nil, into: "en-GB") == nil)
    }
}

struct BundledPromptTests {
    @Test func thePromptsMatchTheServicesAliases() throws {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/ai/prompts")
        for alias in ["watch.plan.v1", "watch.pick.v1", "recap.describe.v1"] {
            let source = try String(contentsOf: tools.appendingPathComponent("\(alias).txt"), encoding: .utf8)
            #expect(BundledPrompts.text(alias) == source, "\(alias)")
        }
    }
}

struct StyledLineTests {
    @Test func stylesSurviveTheTripThroughAttributedText() {
        guard #available(macOS 26.4, *) else { return }
        let line = TraktCommentText("Read **this** and [spoiler]*that*[/spoiler] at https://trakt.tv now").lines[0]
        #expect(StyledLine.runs(StyledLine.attributed(line)) == line.runs)
    }
}

/// Whether this Mac runs Apple Intelligence's model, which the live tests need.
private var modelIsAvailable: Bool {
    guard #available(macOS 26.0, *) else { return false }
    return SystemLanguageModel.default.isAvailable
}

/// Runs against the real models on a Mac with Apple Intelligence; skipped where it is off.
@Suite(.serialized, .enabled(if: modelIsAvailable))
struct LiveModelTests {
    @Test func theModelTranslatesAndKeepsSpoilersInPlace() async throws {
        guard #available(macOS 26.0, *) else { return }
        let translator = ModelTextTranslator()
        #expect(await translator.readiness(from: "es", to: "en") == .ready)
        #expect(await translator.readiness(from: "fi", to: "en") == .unsupported)
        let english = try await translator.translate(markup: "Me encantó. [spoiler]El padre muere al final.[/spoiler] La música es preciosa.", from: "es", to: "en")
        let text = TraktCommentText(english)
        #expect(text.hasInlineSpoilers)
        #expect(LanguageDetector.language(of: text.plainText) == "en")
        #expect(text.runs.first { $0.isSpoiler }?.text.lowercased().contains("father") == true)
    }

    @Test func thePlanReadsLimitsFromARequest() async throws {
        guard #available(macOS 26.0, *) else { return }
        let brain = try #require(OnDeviceBrain(appLanguage: "en", translator: nil))
        let reply = try await brain.ask(alias: WatchPicker.planAlias, input: WatchPicker.planInput("a 90s comedy under two hours for the whole family", year: 2026), language: "English")
        let plan = try #require(WatchPicker.plan(from: reply))
        #expect(plan.kind == .movie || plan.kind == nil)
        #expect(plan.maxMinutes == 120)
        #expect(plan.fromYear == 1990)
        #expect(plan.toYear == 1999)
        #expect(plan.family)
    }

    @Test func picksComeOnlyFromTheOfferedNumbers() async throws {
        guard #available(macOS 26.0, *) else { return }
        let brain = try #require(OnDeviceBrain(appLanguage: "en", translator: nil))
        let input = """
            They asked: something light and funny
            Choose up to 3.
            Titles:
            1|Paddington 2|2017|movie|Comedy, Family|104|7.8|PG|
            2|Hereditary|2018|movie|Horror|127|7.3|R|
            3|Hot Fuzz|2007|movie|Action, Comedy|121|7.8|R|
            4|Sicario|2015|movie|Thriller, Crime|121|7.6|R|
            5|The Grand Budapest Hotel|2014|movie|Comedy|99|8.1|R|
            """
        let reply = try await brain.ask(alias: WatchPicker.pickAlias, input: input, language: "English")
        let data = try #require(reply.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let picks = try #require(object["picks"] as? [[String: Any]])
        let ids = picks.compactMap { $0["id"] as? Int }
        #expect(!ids.isEmpty)
        #expect(ids.allSatisfy { (1...5).contains($0) })
        #expect(!ids.contains(2))
    }

    @Test func theRecapRetellsOnlyTheDescriptions() async throws {
        guard #available(macOS 26.0, *) else { return }
        let brain = try #require(OnDeviceBrain(appLanguage: "en", translator: nil))
        let episodes = [
            DescribedEpisode(id: "1", code: "S1 · E1", title: "Pilot", description: "Mara takes a job at a failing lighthouse and finds a stranger washed up on the rocks."),
            DescribedEpisode(id: "2", code: "S1 · E2", title: "Fog", description: "The stranger claims to remember nothing, but Mara finds a map hidden in his coat."),
        ]
        let reply = try await brain.ask(alias: DescribedRecap.alias, input: DescribedRecap.input(show: "Lantern", episodes: episodes), language: "English")
        let recap = try #require(DescribedRecap.recap(from: reply))
        #expect(recap.contains("Mara"))
        #expect(!recap.lowercased().hasPrefix("previously"))
    }
}

/// Runs against Apple's Translation on a Mac where the languages are installed; skipped where they are not.
@Suite(.serialized)
struct LiveTranslationTests {
    @Test func translationKeepsSpoilersEmphasisAndLinks() async throws {
        guard #available(macOS 26.4, *) else { return }
        let translator = SystemTextTranslator()
        guard await translator.readiness(from: "es", to: "en") == .ready else { return }
        let markup = "Me encantó la película. **La actuación** es increíble. [spoiler]Al final el padre muere.[/spoiler] Más en https://trakt.tv/movies/x\n> Una cita aquí."
        let english = TraktCommentText(try await translator.translate(markup: markup, from: "es", to: "en"))
        #expect(LanguageDetector.language(of: english.plainText) == "en")
        #expect(english.runs.contains { $0.isSpoiler && $0.text.lowercased().contains("father") })
        #expect(english.runs.contains { $0.styles.contains(.bold) })
        #expect(english.runs.contains { $0.link?.absoluteString == "https://trakt.tv/movies/x" })
        #expect(english.runs.contains { $0.styles.contains(.quote) })
    }
}
