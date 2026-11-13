import CrucibleCore
import Foundation

/// The answers the demo gives where Crucible's hosted model would: picks for What to Watch's example requests and a
/// recap of the episodes the demo library starts with as watched. They were written once by the hosted model from the
/// demo's own library, in every language of the app, and are bundled with it, so asking in the demo uses no network.
package struct DemoBrain: HostedBrainProviding {
    private static let bundled = DemoAnswers.bundled()
    private static let pause = Duration.milliseconds(700)

    private let answers: DemoAnswers?

    package init() {
        answers = Self.bundled
    }

    init(answers: DemoAnswers?) {
        self.answers = answers
    }

    package func answers(alias: String, input: String, language: String) -> Bool {
        reply(alias: alias, input: input, language: language) != nil
    }

    package func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String {
        guard let reply = reply(alias: alias, input: input, language: language) else { throw .unavailable }
        try? await Task.sleep(for: Self.pause)
        return reply
    }

    /// What the hosted model would have replied, or nil when nothing was prepared for `input`.
    func reply(alias: String, input: String, language: String) -> String? {
        guard let answers else { return nil }
        switch alias {
        case WatchPicker.planAlias:
            return example(asked(in: input), in: answers)?.plan
        case WatchPicker.pickAlias:
            return example(asked(in: input), in: answers).flatMap { Self.picks($0.spoken(language), among: input) }
        case DescribedRecap.alias:
            guard let recap = answers.recaps.first(where: { $0.input == input })?.spoken(language) else { return nil }
            return Self.json(["recap": recap])
        default:
            return nil
        }
    }

    /// The request a message carries on its "They asked:" line.
    private func asked(in input: String) -> String? {
        let opening = "They asked: "
        return input.components(separatedBy: "\n").first { $0.hasPrefix(opening) }.map { String($0.dropFirst(opening.count)) }
    }

    /// The prepared answer of the example that reads `request` in the language the app is shown in.
    private func example(_ request: String?, in answers: DemoAnswers) -> DemoAnswers.Example? {
        guard let request, let place = WatchCopy.examples.firstIndex(where: { WatchPicker.cleaned($0) == request }) else { return nil }
        return answers.watch.indices.contains(place) ? answers.watch[place] : nil
    }

    /// The pick reply for the numbered titles of `input`: each prepared pick that is among them, by its number there.
    private static func picks(_ prepared: DemoAnswers.Picks, among input: String) -> String? {
        var numbers: [String: Int] = [:]
        for line in input.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 3, let number = Int(fields[0]) else { continue }
            numbers["\(fields[1])|\(fields[2])"] = number
        }
        let chosen = prepared.picks.compactMap { pick -> [String: Any]? in
            guard let number = numbers["\(pick.title)|\(pick.year.map(String.init) ?? "")"] else { return nil }
            return ["id": number, "why": pick.why]
        }
        return json(["picks": chosen, "note": prepared.note])
    }

    private static func json(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// The file of prepared answers, `Data/answers.json`, as `tools/ai/gen_demo_answers.py` writes it.
struct DemoAnswers: Decodable, Sendable {
    static let fallbackLanguage = "English"

    struct Pick: Decodable, Sendable {
        let title: String
        let year: Int?
        let why: String
    }

    struct Picks: Decodable, Sendable {
        let picks: [Pick]
        let note: String
    }

    /// One example request, in the order `WatchCopy.examples` lists them: the plan the hosted model made of it, and
    /// its picks with their reasons in each language, keyed by the language's English name.
    struct Example: Decodable, Sendable {
        let plan: String
        let answers: [String: Picks]

        func spoken(_ language: String) -> Picks {
            answers[language] ?? answers[DemoAnswers.fallbackLanguage] ?? Picks(picks: [], note: "")
        }
    }

    /// A recap of the episodes a show starts the demo with as watched, keyed by the exact message that asks for it.
    struct Recap: Decodable, Sendable {
        let input: String
        let answers: [String: String]

        func spoken(_ language: String) -> String? {
            answers[language] ?? answers[DemoAnswers.fallbackLanguage]
        }
    }

    let watch: [Example]
    let recaps: [Recap]

    static func bundled() -> DemoAnswers? {
        guard let assets = try? DemoAssets.bundled() else { return nil }
        return load(assets.answers)
    }

    static func load(_ url: URL) -> DemoAnswers? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DemoAnswers.self, from: data)
    }
}
