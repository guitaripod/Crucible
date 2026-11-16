import CrucibleCore
import Foundation
import MidgarCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationModels) && (!os(tvOS) || compiler(>=6.4.2))
import FoundationModels
#endif

/// Apple Intelligence in Crucible, set up at launch: the translator for comments, reviews and descriptions, the languages
/// it translates into, and the on-device model that answers What to Watch and Previously On. A device without any of it
/// keeps the hosted model and shows no translation. On Apple TV the model first runs in tvOS 27.3, so its code builds
/// only with that SDK's compiler (Swift 6.4.2); a build made with an earlier Xcode leaves Apple TV without it.
@MainActor
package enum Intelligence {
    private static var watching = false

    /// Installs what this device can run and learns its languages in the background. Safe to call again, as when the
    /// on-device model finishes downloading.
    package static func configureForLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isScripted(environment) else { return }
        observeForeground()
        #if os(tvOS)
        #if compiler(>=6.4.2)
        if #available(tvOS 27.3, *) { configureModelTranslation() }
        #endif
        #else
        if #available(iOS 26.0, macOS 26.0, *) { configureSystemTranslation() }
        #endif
        #if canImport(FoundationModels) && (!os(tvOS) || compiler(>=6.4.2))
        if #available(iOS 26.0, macOS 26.0, tvOS 27.3, *) { installOnDeviceBrain() }
        #endif
    }

    /// Store captures and scripted UI-test sessions keep the answers and screens they were written for: no translation and
    /// no on-device answers ahead of the scripted model. `CRUCIBLE_INTELLIGENCE=1` keeps both on in such a session, to look
    /// at them in a capture.
    static func isScripted(_ environment: [String: String]) -> Bool {
        guard environment["CRUCIBLE_INTELLIGENCE"] != "1" else { return false }
        let capture = environment["CRUCIBLE_SIGNAL_DIR"] != nil || !(environment["CRUCIBLE_SHOT_SCRIPT"] ?? "").isEmpty
        let brain = environment["CRUCIBLE_BRAIN"] ?? ""
        return capture || (!brain.isEmpty && brain != "live")
    }

    private static var foregroundObserver: NSObjectProtocol?
    /// Learns again whether the on-device model's English answers can be put into the app's language.
    private static var relearn: (@MainActor () -> Void)?

    /// When the app comes back, languages may have been downloaded or removed in Settings, so what was missing is asked
    /// again and the on-device model learns again what it can answer in.
    private static func observeForeground() {
        #if canImport(UIKit)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                TranslationCenter.shared.refreshReadiness()
                relearn?()
            }
        }
        #endif
    }

    /// The language the app is shown in, which recaps and reasons are written in.
    static var appLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    #if !os(tvOS)
    @available(iOS 26.0, macOS 26.0, *)
    private static func configureSystemTranslation() {
        let system = SystemTextTranslator()
        let translator: any TextTranslating = ModelTextTranslator.supportedLanguages().isEmpty ? system : LayeredTranslator(first: system, second: ModelTextTranslator())
        TranslationCenter.shared.translator = translator
        #if os(iOS)
        TranslationCenter.shared.downloadLanguages = { source, target in await TranslationDownload.run(source: source, target: target) }
        #endif
        Task {
            let languages = await SystemTextTranslator.supportedLanguages() + ModelTextTranslator.supportedLanguages()
            TranslationLanguages.setSupported(languages)
            MidgarLog.notice("Translation offers \(TranslationLanguages.available.count) languages, into \(TranslationPreferences.targetLanguage)", category: .lifecycle)
            NotificationCenter.default.post(name: .translationPreferencesChanged, object: nil)
        }
    }
    #endif

    #if canImport(FoundationModels) && (!os(tvOS) || compiler(>=6.4.2))
    @available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
    private static func configureModelTranslation() {
        let languages = ModelTextTranslator.supportedLanguages()
        TranslationCenter.shared.translator = languages.isEmpty ? nil : ModelTextTranslator()
        TranslationLanguages.setSupported(languages)
        MidgarLog.notice("On-device translation: model \(SystemLanguageModel.default.availability), \(TranslationLanguages.available.count) languages", category: .lifecycle)
        NotificationCenter.default.post(name: .translationPreferencesChanged, object: nil)
        watchModelAvailability()
    }

    @available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
    private static func installOnDeviceBrain() {
        guard let brain = OnDeviceBrain(appLanguage: appLanguage, translator: TranslationCenter.shared.translator) else { return }
        HostedBrain.installOnDevice(brain)
        MidgarLog.notice("On-device model: \(SystemLanguageModel.default.availability)", category: .lifecycle)
        relearn = { Task { await brain.learnWhetherAnswersTranslate() } }
        TranslationCenter.shared.readinessChanged = relearn
        relearn?()
        watchModelAvailability()
    }

    /// Sets up again once the model's availability changes, as when Apple Intelligence finishes downloading it, so its
    /// languages and answers appear without a relaunch.
    @available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
    private static func watchModelAvailability() {
        guard !watching else { return }
        watching = true
        observeAvailability()
    }

    @available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
    private static func observeAvailability() {
        withObservationTracking {
            _ = SystemLanguageModel.default.availability
        } onChange: {
            Task { @MainActor in
                configureForLaunch()
                observeAvailability()
            }
        }
    }
    #endif
}
