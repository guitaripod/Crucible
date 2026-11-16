#if canImport(FoundationModels) && (!os(tvOS) || compiler(>=6.4.2))
import CrucibleCore
import Foundation
import FoundationModels
import MidgarCore
#if canImport(os)
import os
#endif

/// What to Watch and Previously On answered by the Apple Intelligence model on this device, with the hosted aliases'
/// own instructions and reply shapes, so the screens read its answers exactly as the service's. Nothing is sent. Where
/// the model does not write the app's language, it answers in English and Apple's Translation puts the words into the
/// app's language; where neither can, it leaves the request to the hosted model.
@available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
package final class OnDeviceBrain: HostedBrainProviding {
    package static let aliases: Set<String> = [WatchPicker.planAlias, WatchPicker.pickAlias, DescribedRecap.alias]

    /// Room kept free in the context for the model's answer and the reply's shape.
    private static let answerRoom = 700

    private let prompts: [String: String]
    private let appLanguage: String
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let translator: (any TextTranslating)?

    private struct State {
        /// Whether English answers can be translated into the app's language, once that is known.
        var translatesAnswers = false
    }

    /// The model with the bundled instructions; nil when they are missing from the build.
    package init?(appLanguage: String, translator: (any TextTranslating)?) {
        var prompts: [String: String] = [:]
        for alias in Self.aliases {
            guard let text = BundledPrompts.text(alias) else { return nil }
            prompts[alias] = text
        }
        self.prompts = prompts
        self.appLanguage = appLanguage
        self.translator = translator
    }

    package var isOnDevice: Bool { true }

    package var isReady: Bool { SystemLanguageModel.default.isAvailable }

    /// A plan is only figures, so any app language will do; a pick's reasons and a recap need words in the app's
    /// language, which the model writes or Translation can put them into.
    package func answers(alias: String, input: String, language: String) -> Bool {
        guard Self.aliases.contains(alias), isReady else { return false }
        if alias != WatchPicker.planAlias, !writesAppLanguage, !state.withLock(\.translatesAnswers) { return false }
        guard alias != DescribedRecap.alias, let request = Self.request(in: input) else { return true }
        return readsRequest(request)
    }

    /// Finds out whether English answers can be put into the app's language, which the model may not write itself.
    package func learnWhetherAnswersTranslate() async {
        guard !writesAppLanguage, let translator else { return }
        let ready = await translator.readiness(from: "en", to: appLanguage) == .ready
        state.withLock { $0.translatesAnswers = ready }
    }

    package func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String {
        guard let instructions = prompts[alias] else { throw .unavailable }
        let answerLanguage = writesAppLanguage ? appLanguage : "en"
        let filled = instructions.replacingOccurrences(of: "{language}", with: ModelTextTranslator.englishName(answerLanguage))
        let message = await englishRequest(in: input)
        switch alias {
        case WatchPicker.planAlias: return try await plan(message, instructions: filled)
        case WatchPicker.pickAlias: return try await pick(message, instructions: filled)
        default: return try await recap(message, instructions: filled)
        }
    }

    // MARK: - Aliases

    private func plan(_ input: String, instructions: String) async throws(HostedBrainError) -> String {
        let reply: PlanReply
        do {
            reply = try await ModelGate.shared.run {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
                return try await session.respond(to: input, generating: PlanReply.self, options: GenerationOptions(samplingMode: .greedy)).content
            }
        } catch {
            MidgarLog.notice("On-device plan failed: \(String(describing: error))", category: .lifecycle)
            throw ModelFailure.brain(error)
        }
        return Self.json(PlanWire(reply))
    }

    /// The picks among the titles that fitted the model's context; a number it was not shown is dropped, as the hosted
    /// model can only pick what it was sent.
    private func pick(_ input: String, instructions: String) async throws(HostedBrainError) -> String {
        let fitted = await fitting(input, instructions: instructions)
        let message = fitted.message
        let reply: PickReply
        do {
            reply = try await ModelGate.shared.run {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
                return try await session.respond(to: message, generating: PickReply.self, options: GenerationOptions(temperature: 0.3)).content
            }
        } catch {
            MidgarLog.notice("On-device pick failed: \(String(describing: error))", category: .lifecycle)
            throw ModelFailure.brain(error)
        }
        var picks: [PickWire.Pick] = []
        for pick in reply.picks where pick.id >= 1 && pick.id <= fitted.titles {
            picks.append(PickWire.Pick(id: pick.id, why: try await inAppLanguage(pick.why)))
        }
        let note = picks.count >= 3 ? "" : try await inAppLanguage(reply.note)
        return Self.json(PickWire(picks: picks, note: note))
    }

    private func recap(_ input: String, instructions: String) async throws(HostedBrainError) -> String {
        let text: String
        do {
            text = try await ModelGate.shared.run {
                let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model, instructions: instructions)
                return try await session.respond(to: input, options: GenerationOptions(temperature: 0.3)).content
            }
        } catch {
            MidgarLog.notice("On-device recap failed: \(String(describing: error))", category: .lifecycle)
            throw ModelFailure.brain(error)
        }
        return Self.json(RecapWire(recap: try await inAppLanguage(Self.unquoted(text))))
    }

    // MARK: - Languages

    private var writesAppLanguage: Bool {
        SystemLanguageModel.default.supportedLanguages.contains { TranslationLanguages.isSame($0.minimalIdentifier, appLanguage) }
    }

    /// Whether the model can read a request in its language, directly or once Translation has put it into English.
    private func readsRequest(_ request: String) -> Bool {
        guard let language = LanguageDetector.language(of: request) else { return true }
        if modelWrites(language) { return true }
        return translator != nil
    }

    private func modelWrites(_ language: String) -> Bool {
        SystemLanguageModel.default.supportedLanguages.contains { TranslationLanguages.isSame($0.minimalIdentifier, language) }
    }

    /// The message with its request put into English when the model does not read the language it is in. Where that
    /// cannot be done the request goes as it was written, which the model often still understands well enough to plan.
    private func englishRequest(in input: String) async -> String {
        guard let request = Self.request(in: input), let language = LanguageDetector.language(of: request), !modelWrites(language),
              let translator, await translator.readiness(from: language, to: "en") == .ready,
              let english = try? await translator.translate(markup: request, from: language, to: "en") else { return input }
        return input.replacingOccurrences(of: Self.requestPrefix + request, with: Self.requestPrefix + english)
    }

    /// An English answer put into the app's language when the model could not write it. A translation that fails fails
    /// the answer, so the hosted model answers in the right language instead of the screen showing English.
    private func inAppLanguage(_ text: String) async throws(HostedBrainError) -> String {
        guard !writesAppLanguage, !text.isEmpty else { return text }
        guard let translator else { throw .unavailable }
        do throws(TranslationFailure) {
            return try await translator.translate(markup: text, from: "en", to: appLanguage)
        } catch {
            state.withLock { $0.translatesAnswers = false }
            MidgarLog.notice("On-device answer not translated into \(appLanguage): \(error)", category: .lifecycle)
            throw .failed
        }
    }

    // MARK: - Fitting

    /// The pick message cut to the candidates that fit the model's context with room for its answer, and how many titles
    /// it keeps. Candidates come best first, so the last ones go.
    private func fitting(_ input: String, instructions: String) async -> (message: String, titles: Int) {
        let budget = SystemLanguageModel.default.contextSize - Self.answerRoom
        var lines = input.components(separatedBy: "\n")
        guard let titles = lines.firstIndex(of: "Titles:") else { return (input, 0) }
        var low = 0
        var high = lines.count - titles - 1
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = (lines[...titles] + lines[(titles + 1)..<(titles + 1 + middle)]).joined(separator: "\n")
            if await tokens(instructions + "\n" + candidate) <= budget { low = middle } else { high = middle - 1 }
        }
        lines = Array(lines[...(titles + low)])
        return (lines.joined(separator: "\n"), low)
    }

    /// How many tokens `text` takes, counted by the model where it can, else estimated from its length.
    private func tokens(_ text: String) async -> Int {
        if #available(iOS 26.4, macOS 26.4, tvOS 27.3, *), let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return count
        }
        return text.utf8.count / 3
    }

    // MARK: - Wire

    private static let requestPrefix = "They asked: "

    /// The person's own words in a What to Watch message, or nil for a message without them.
    static func request(in input: String) -> String? {
        input.components(separatedBy: "\n").first { $0.hasPrefix(requestPrefix) }.map { String($0.dropFirst(requestPrefix.count)) }
    }

    /// A recap without the quotation marks the model sometimes wraps it in.
    static func unquoted(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}"]
        while let first = trimmed.first, let last = trimmed.last, quotes.contains(first), quotes.contains(last), trimmed.count > 1 {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

@available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
@Generable
struct PlanReply {
    @Guide(description: "movie, show or any")
    var kind: Kind
    @Guide(description: "unseen, seen or any")
    var watched: Watched
    @Guide(description: "The longest running time allowed in minutes, or 0 when none is stated")
    var maxMinutes: Int
    @Guide(description: "The shortest running time in minutes, only for a request for something long, else 0")
    var minMinutes: Int
    @Guide(description: "The first year of an era they name, or 0 when none")
    var fromYear: Int
    @Guide(description: "The last year of an era they name, or 0 when none")
    var toYear: Int
    @Guide(description: "True only when children or the whole family will be watching")
    var family: Bool
    @Guide(description: "How many titles they ask for, from 1 to 8, or 0 when they do not say")
    var count: Int

    @Generable
    enum Kind: String { case movie, show, `any` }

    @Generable
    enum Watched: String { case unseen, seen, `any` }
}

@available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
@Generable
struct PickReply {
    @Guide(description: "The chosen titles, the best fit first", .maximumCount(8))
    var picks: [Choice]
    @Guide(description: "Only when fewer than three were chosen: one short sentence on what the library lacks, else empty")
    var note: String

    @Generable
    struct Choice {
        @Guide(description: "The number of a title from the list")
        var id: Int
        @Guide(description: "One sentence of at most 14 words on the title and why it fits the request")
        var why: String
    }
}

/// The plan alias's reply shape, as the service sends it.
private struct PlanWire: Encodable {
    let kind: String
    let watched: String
    let max_minutes: Int?
    let min_minutes: Int?
    let from_year: Int?
    let to_year: Int?
    let family: Bool
    let count: Int?

    @available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
    init(_ reply: PlanReply) {
        let positive: (Int) -> Int? = { $0 > 0 ? $0 : nil }
        kind = reply.kind.rawValue
        watched = reply.watched.rawValue
        max_minutes = positive(reply.maxMinutes)
        min_minutes = positive(reply.minMinutes)
        from_year = positive(reply.fromYear)
        to_year = positive(reply.toYear)
        family = reply.family
        count = positive(reply.count)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(watched, forKey: .watched)
        try container.encode(max_minutes, forKey: .max_minutes)
        try container.encode(min_minutes, forKey: .min_minutes)
        try container.encode(from_year, forKey: .from_year)
        try container.encode(to_year, forKey: .to_year)
        try container.encode(family, forKey: .family)
        try container.encode(count, forKey: .count)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, watched, max_minutes, min_minutes, from_year, to_year, family, count
    }
}

/// The pick alias's reply shape.
private struct PickWire: Encodable {
    struct Pick: Encodable {
        let id: Int
        let why: String
    }

    let picks: [Pick]
    let note: String
}

/// The recap alias's reply shape.
private struct RecapWire: Encodable {
    let recap: String
}
#endif
