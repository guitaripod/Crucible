import Foundation

extension Notification.Name {
    /// Posted on the main thread when the language to translate into, or whether translation is automatic, changed.
    package static let translationPreferencesChanged = Notification.Name("crucible.translationPreferencesChanged")
}

/// What a person chose for translation: the language text lands in, and whether it is translated as it loads or only
/// when they ask. Both live in Settings › Translation.
package enum TranslationPreferences {
    private static let languageKey = "translation.language"
    private static let automaticKey = "translation.automatic"

    /// The language chosen in Settings, or nil to follow the person's own languages.
    package static var chosenLanguage: String? {
        get { UserDefaults.standard.string(forKey: languageKey).flatMap(TranslationLanguages.catalogLanguage(for:)) }
        set {
            if let newValue, let language = TranslationLanguages.catalogLanguage(for: newValue) {
                UserDefaults.standard.set(language, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
            postChange()
        }
    }

    /// Whether text in another language is translated as it loads, with Show Original a tap away. On by default.
    package static var translatesAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: automaticKey)
            postChange()
        }
    }

    /// The language text is translated into: the one chosen in Settings while the device offers it, otherwise the first of
    /// the app's language and the person's preferred languages that it offers, and English when none is.
    package static var targetLanguage: String {
        let available = TranslationLanguages.available
        if let chosen = chosenLanguage, available.contains(chosen) { return chosen }
        return automaticLanguage(available: available, preferred: personalLanguages)
    }

    /// The first of `preferred` that `available` holds, else English.
    package static func automaticLanguage(available: [String], preferred: [String]) -> String {
        for identifier in preferred {
            if let match = available.first(where: { TranslationLanguages.isSame($0, identifier) }) { return match }
        }
        return available.first { $0 == "en" } ?? available.first ?? "en"
    }

    /// The app's own language first, then the languages the person set for the device, in their order.
    package static var personalLanguages: [String] {
        #if canImport(Darwin)
        let app = Bundle.main.preferredLocalizations.first.map { [$0] } ?? []
        return app + Locale.preferredLanguages
        #else
        return [LocalizationCatalog.shared.currentLanguage] + Locale.preferredLanguages
        #endif
    }

    private static func postChange() {
        let post: @Sendable () -> Void = { NotificationCenter.default.post(name: .translationPreferencesChanged, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
