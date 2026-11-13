import Foundation
import MidgarCore
import os

/// Why Crucible's hosted model gave no answer, each with its own next step for the person.
package enum HostedBrainError: Error, Equatable, Sendable {
    /// This build or session has no hosted model: a source build, or the demo, which uses no network.
    case unavailable
    case offline
    /// The service answers only for Crucible Pro and this person's allowance without it is used.
    case needsPro
    /// Today's allowance is used; it returns at the date.
    case allowanceUsed(resetsAt: Date)
    case busy
    /// The model would not work with what was sent.
    case declined
    case failed
}

/// The hosted model behind What to Watch and a Previously On written from episode descriptions. The App Store build
/// supplies it from `CrucibleStore`, on the anonymous Midgar ID that Crucible Pro already uses; a source build has none.
package protocol HostedBrainProviding: Sendable {
    /// Sends `input` to the named alias, which holds the instructions and the shape of the reply on the service, and
    /// returns the reply's text. `language` is the English name of the language to answer in.
    func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String
}

/// The one hosted model of the process, installed at launch. Nothing reaches it unless a person asks for an answer.
package enum HostedBrain {
    private static let provider = OSAllocatedUnfairLock<(any HostedBrainProviding)?>(initialState: nil)

    package static func install(_ brain: any HostedBrainProviding) {
        provider.withLock { $0 = brain }
    }

    /// Whether a hosted answer can be asked for at all. The demo never has one: it uses no network.
    package static var isAvailable: Bool {
        provider.withLock { $0 != nil } && !UserDefaults.standard.bool(forKey: DemoMode.activeKey)
    }

    package static func ask(alias: String, input: String) async throws(HostedBrainError) -> String {
        guard isAvailable, let brain = provider.withLock({ $0 }) else { throw .unavailable }
        return try await brain.ask(alias: alias, input: input, language: language)
    }

    /// The English name of the language the app is shown in, which the service's instructions answer in:
    /// "Finnish", "Portuguese (Brazil)", "Chinese, Simplified".
    package static var language: String {
        languageName(Bundle.main.preferredLocalizations.first ?? "en")
    }

    package static func languageName(_ identifier: String) -> String {
        let name = Locale(identifier: "en_US").localizedString(forIdentifier: identifier) ?? "English"
        return String(name.filter { $0.isLetter || $0.isNumber || " -_(),".contains($0) }.prefix(64))
    }

    /// Installs the scripted model of debug sessions and UI tests when `CRUCIBLE_BRAIN` asks for one.
    package static func configureForLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        if let scripted = ScriptedHostedBrain(environment: environment) {
            install(scripted)
            MidgarLog.notice("Debug session: hosted model is scripted", category: .lifecycle)
        }
        #endif
    }
}

#if DEBUG
/// A hosted model that answers from the environment, for UI tests and captures: no network, the same shapes.
///
/// - `CRUCIBLE_BRAIN`: `ok` answers every alias, `offline`, `limit`, `pro`, `busy` or `fail` refuse the way the
///   service would.
/// - `CRUCIBLE_BRAIN_DELAY_MS`: how long an answer takes, 600 by default.
package struct ScriptedHostedBrain: HostedBrainProviding {
    private let behavior: String
    private let delay: Duration

    package init?(environment: [String: String]) {
        guard let behavior = environment["CRUCIBLE_BRAIN"], !behavior.isEmpty else { return nil }
        self.behavior = behavior
        self.delay = .milliseconds(environment["CRUCIBLE_BRAIN_DELAY_MS"].flatMap(Int.init) ?? 600)
    }

    package func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String {
        try? await Task.sleep(for: delay)
        switch behavior {
        case "offline": throw .offline
        case "limit": throw .allowanceUsed(resetsAt: Date().addingTimeInterval(3 * 3600))
        case "pro": throw .needsPro
        case "busy": throw .busy
        case "fail": throw .failed
        default: return Self.answer(alias: alias, input: input)
        }
    }

    /// What the service would say: no limits for a plan, the first candidates for a pick, a fixed paragraph for a recap.
    static func answer(alias: String, input: String) -> String {
        switch alias {
        case WatchPicker.planAlias:
            return #"{"kind":"any","watched":"any","max_minutes":null,"min_minutes":null,"from_year":null,"to_year":null,"family":false,"count":null}"#
        case WatchPicker.pickAlias:
            let numbers = input.split(separator: "\n").compactMap { line in line.split(separator: "|").first.flatMap { Int($0) } }
            let reasons = ["A sharp, fast-moving story that suits tonight.", "Warm and easy to settle into.", "Tense from the first scene and hard to stop.", "A quiet one with a lot of heart."]
            let picks = numbers.prefix(4).enumerated().map { place, number in #"{"id":\#(number),"why":"\#(reasons[place % reasons.count])"}"# }
            return #"{"picks":[\#(picks.joined(separator: ","))],"note":""}"#
        default:
            return #"{"recap":"The crew pulled off the first job and paid for it at once. An old rival surfaced with a claim on the money, the plan for the second job fell apart over who could be trusted, and by the end one of them had quietly made a deal of their own."}"#
        }
    }
}
#endif
