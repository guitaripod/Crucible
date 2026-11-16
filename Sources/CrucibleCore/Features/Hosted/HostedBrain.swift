import Foundation
import MidgarCore
#if canImport(os)
import os
#endif

/// Why Crucible's hosted model gave no answer, each with its own next step for the person.
package enum HostedBrainError: Error, Equatable, Sendable {
    /// This build or session has no answer to give: a source build, or a request the demo holds no prepared answer for.
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

/// The model behind What to Watch and a Previously On written from episode descriptions. The App Store build supplies
/// the hosted one from `CrucibleStore`, on the anonymous Midgar ID that Crucible Pro already uses; a source build has
/// none. A device with Apple Intelligence also answers on its own model, which goes first wherever it can.
package protocol HostedBrainProviding: Sendable {
    /// Sends `input` to the named alias, which holds the instructions and the shape of the reply on the service, and
    /// returns the reply's text. `language` is the English name of the language to answer in.
    func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String

    /// Whether this model has an answer for `input`. The hosted one always tries; the demo's holds only the answers
    /// prepared for it, and the device's own only what fits it in a language it writes.
    func answers(alias: String, input: String, language: String) -> Bool

    /// Whether the model can answer at all right now: the device's own waits until Apple Intelligence is ready.
    var isReady: Bool { get }

    /// Whether the answer is written on this device, so nothing is sent to answer it.
    var isOnDevice: Bool { get }
}

extension HostedBrainProviding {
    package func answers(alias: String, input: String, language: String) -> Bool { true }
    package var isReady: Bool { true }
    package var isOnDevice: Bool { false }
}

/// The models of the process, installed at launch: the device's own first, then the hosted one. Nothing reaches the
/// hosted model unless a person asks for an answer and the device's own cannot give it. The demo uses no network, so
/// while it runs the answers come from the ones prepared for its library instead.
package enum HostedBrain {
    private static let provider = OSAllocatedUnfairLock<(any HostedBrainProviding)?>(initialState: nil)
    private static let onDeviceProvider = OSAllocatedUnfairLock<(any HostedBrainProviding)?>(initialState: nil)
    private static let demoProvider = OSAllocatedUnfairLock<(any HostedBrainProviding)?>(initialState: nil)

    package static func install(_ brain: any HostedBrainProviding) {
        provider.withLock { $0 = brain }
    }

    /// Takes the installed model away, as when the person removes their own model on Linux; the demo's stays.
    package static func remove() {
        provider.withLock { $0 = nil }
    }

    /// Installs the model on this device, which answers ahead of the hosted one. Called once at launch where Apple
    /// Intelligence can run.
    package static func installOnDevice(_ brain: any HostedBrainProviding) {
        onDeviceProvider.withLock { $0 = brain }
    }

    /// Installs the answers the demo gives. Called once by an app entry point that links `CrucibleDemo`.
    package static func installDemo(_ brain: any HostedBrainProviding) {
        demoProvider.withLock { $0 = brain }
    }

    private static var isDemo: Bool { UserDefaults.standard.bool(forKey: DemoMode.activeKey) }

    /// The models that can answer now, in the order they are asked: the demo's alone while it runs, else the device's own
    /// and then the hosted one.
    private static var layers: HostedBrainLayers {
        if isDemo { return HostedBrainLayers(demoProvider.withLock { $0 }.map { [$0] } ?? []) }
        return HostedBrainLayers([onDeviceProvider.withLock { $0 }, provider.withLock { $0 }].compactMap { $0 })
    }

    /// Whether an answer can be asked for at all: the device's own model or the hosted one, the prepared answers in the demo.
    package static var isAvailable: Bool { layers.isAvailable }

    /// Whether a person's own words are answered. The demo answers only the requests it was prepared for.
    package static var takesAnyRequest: Bool { !isDemo }

    /// Whether `input` would get an answer, which in the demo is true only for what was prepared.
    package static func canAnswer(alias: String, input: String) -> Bool {
        layers.canAnswer(alias: alias, input: input, language: language)
    }

    /// Where the answers to `aliases` come from, which each feature's words about what leaves the device follow.
    package static func route(for aliases: [String], input: String = "") -> HostedBrainRoute {
        layers.route(for: aliases, input: input, language: language)
    }

    /// The answer from the first model that gives one: the device's own, and when it cannot answer, the hosted one.
    package static func ask(alias: String, input: String) async throws(HostedBrainError) -> String {
        try await layers.ask(alias: alias, input: input, language: language)
    }

    /// The English name of the language the app is shown in, which the service's instructions answer in:
    /// "Finnish", "Portuguese (Brazil)", "Chinese, Simplified".
    package static var language: String {
        #if canImport(Darwin)
        languageName(Bundle.main.preferredLocalizations.first ?? "en")
        #else
        languageName(LocalizationCatalog.shared.currentLanguage)
        #endif
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

/// Models in the order they are asked, the ones not ready left out.
package struct HostedBrainLayers: Sendable {
    private let brains: [any HostedBrainProviding]

    package init(_ brains: [any HostedBrainProviding]) {
        self.brains = brains.filter(\.isReady)
    }

    package var isAvailable: Bool { !brains.isEmpty }

    package func canAnswer(alias: String, input: String, language: String) -> Bool {
        brains.contains { $0.answers(alias: alias, input: input, language: language) }
    }

    /// Where the answers to `aliases` come from: all on this device, on this device with the hosted model as the fallback,
    /// or the hosted model.
    package func route(for aliases: [String], input: String, language: String) -> HostedBrainRoute {
        let answering = brains.filter { brain in aliases.allSatisfy { brain.answers(alias: $0, input: input, language: language) } }
        guard answering.first?.isOnDevice == true else { return .hosted }
        return answering.contains { !$0.isOnDevice } ? .onDeviceFirst : .onDevice
    }

    /// The answer from the first model that gives one. A model on the device that fails hands the request on to the next;
    /// the last one's refusal is the one the person sees.
    package func ask(alias: String, input: String, language: String) async throws(HostedBrainError) -> String {
        let answering = brains.filter { $0.answers(alias: alias, input: input, language: language) }
        guard let last = answering.last else { throw .unavailable }
        for brain in answering.dropLast() {
            do {
                return try await brain.ask(alias: alias, input: input, language: language)
            } catch {
                MidgarLog.notice("On-device model gave no answer for \(alias) (\(error)); asking the next model", category: .lifecycle)
            }
        }
        return try await last.ask(alias: alias, input: input, language: language)
    }
}

/// Where a feature's answers come from, for what it tells the person leaves the device.
package enum HostedBrainRoute: Equatable, Sendable {
    /// Apple Intelligence answers on this device and nothing is sent.
    case onDevice
    /// Apple Intelligence answers on this device; only when it cannot does the hosted model get the request.
    case onDeviceFirst
    /// The hosted model answers.
    case hosted
}

#if DEBUG
/// A hosted model that answers from the environment, for UI tests and captures: no network, the same shapes.
///
/// - `CRUCIBLE_BRAIN`: `ok` answers every alias, `offline`, `limit`, `pro`, `busy` or `fail` refuse the way the
///   service would. `live` is not scripted: it asks an app entry point to install the real model in a session that
///   would otherwise have none (the Apple TV app against the mock server).
/// - `CRUCIBLE_BRAIN_DELAY_MS`: how long an answer takes, 600 by default.
package struct ScriptedHostedBrain: HostedBrainProviding {
    private let behavior: String
    private let delay: Duration

    package init?(environment: [String: String]) {
        guard let behavior = environment["CRUCIBLE_BRAIN"], !behavior.isEmpty, behavior != "live" else { return nil }
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
