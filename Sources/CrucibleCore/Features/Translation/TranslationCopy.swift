import Foundation

/// The words of on-device translation, shared by iPhone, iPad and Apple TV.
package enum TranslationCopy {
    package static let title = String(localized: "Translation", comment: "Settings category for translating comments, reviews and descriptions")
    package static let translate = String(localized: "Translate", comment: "Button that translates a comment or description into the reader's language")
    package static let translating = String(localized: "Translating…", comment: "Shown while a comment or description is being translated")
    package static let showOriginal = String(localized: "Show Original", comment: "Button that shows a translated comment or description as it was written")
    package static let showTranslation = String(localized: "Show Translation", comment: "Button that shows the translation again after Show Original")
    package static let translated = String(localized: "Translated", comment: "Short badge on a comment card that was translated into the reader's language")
    package static let failed = String(localized: "Couldn\u{2019}t translate", comment: "Shown under a comment or description that could not be translated")
    package static let tryAgain = String(localized: "Try Again", comment: "Button that retries a translation that failed")
    package static let translateToEnglish = String(localized: "Translate to English", comment: "Composer button that translates the comment being written into English, which Trakt requires")
    package static let translatedToEnglish = String(localized: "Translated to English. Check it reads the way you meant before posting.", comment: "Composer note after the comment was translated into English")

    /// "Translated from Spanish".
    package static func translatedFrom(_ language: String) -> String {
        String(localized: "Translated from \(language)", comment: "Under a translated comment or description, e.g. Translated from Spanish")
    }

    /// "Translate from Spanish".
    package static func translateFrom(_ language: String) -> String {
        String(localized: "Translate from \(language)", comment: "Button under a comment or description in another language, e.g. Translate from Spanish")
    }

    /// The Automatic choice of the language setting, naming the language it lands on: "Automatic (Finnish)".
    package static func automaticLanguage(_ language: String) -> String {
        String(localized: "Automatic (\(language))", comment: "Translation language option that follows the app and device languages, e.g. Automatic (Finnish)")
    }

    package static let languageSetting = String(localized: "Translate Into", comment: "Setting: the language comments, reviews and descriptions are translated into")
    package static let languageExplanation = String(localized: "Automatic follows the language Crucible is shown in, then the languages you set for this device.", comment: "Explanation of the Translate Into setting")
    package static let automaticSetting = String(localized: "Translate Automatically", comment: "Setting: translate text in another language as it loads")
    package static let automaticExplanation = String(localized: "Comments, reviews and descriptions in another language appear in yours as they load, with Show Original a tap away. Off, each one offers Translate instead.", comment: "Explanation of the Translate Automatically setting")
    package static let categoryExplanation = String(localized: "Comments, reviews and descriptions in your language, translated on this device.", comment: "Explanation of the Translation settings category")
    package static let keywords = String(localized: "translate, translation, language, foreign, Apple Intelligence, comments, reviews", comment: "Search keywords for the translation settings, comma separated")

    /// The line under the Translation category: the language and whether it is automatic, "Finnish · Automatic".
    package static func summary(language: String, automatic: Bool) -> String {
        let mode = automatic
            ? String(localized: "Automatic", comment: "Translation summary: text is translated as it loads")
            : String(localized: "On Request", comment: "Translation summary: text is translated only when asked")
        return "\(language) · \(mode)"
    }
}
