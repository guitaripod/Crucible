import CrucibleCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence in Crucible, set up at launch: the translator for comments, reviews and descriptions, the languages
/// it translates into, and the on-device model that answers What to Watch and Previously On. A device without any of it
/// keeps the hosted model and shows no translation.
@MainActor
package enum Intelligence {
    private static var watching = false

    /// Installs what this device can run and learns its languages in the background. Safe to call again, as when the
    /// on-device model finishes downloading.
    package static func configureForLaunch() {
        #if os(tvOS)
        if #available(tvOS 27.3, *) { configureModelTranslation() }
        #else
        if #available(iOS 26.0, macOS 26.0, *) { configureSystemTranslation() }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, tvOS 27.3, *) { installOnDeviceBrain() }
        #endif
    }

    /// The language the app is shown in, which recaps and reasons are written in.
    static var appLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    #if !os(tvOS)
    @available(iOS 26.0, macOS 26.0, *)
    private static func configureSystemTranslation() {
        let translator = SystemTextTranslator()
        TranslationCenter.shared.translator = translator
        #if os(iOS)
        TranslationCenter.shared.downloadLanguages = { source, target in await TranslationDownload.run(source: source, target: target) }
        #endif
        Task {
            let languages = await SystemTextTranslator.supportedLanguages()
            TranslationLanguages.setSupported(languages)
            NotificationCenter.default.post(name: .translationPreferencesChanged, object: nil)
        }
    }
    #endif

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
    private static func configureModelTranslation() {
        let languages = ModelTextTranslator.supportedLanguages()
        TranslationCenter.shared.translator = languages.isEmpty ? nil : ModelTextTranslator()
        TranslationLanguages.setSupported(languages)
        NotificationCenter.default.post(name: .translationPreferencesChanged, object: nil)
        watchModelAvailability()
    }

    @available(iOS 26.0, macOS 26.0, tvOS 27.3, *)
    private static func installOnDeviceBrain() {
        guard let brain = OnDeviceBrain(appLanguage: appLanguage, translator: TranslationCenter.shared.translator) else { return }
        HostedBrain.installOnDevice(brain)
        Task { await brain.learnWhetherAnswersTranslate() }
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
