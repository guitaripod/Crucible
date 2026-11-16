import CrucibleCore
import Foundation

/// What People Say in the reader's language: Trakt writes each praised or criticised aspect in English, and with Translate
/// Automatically on, each one is shown translated once its translation lands.
@MainActor
package enum TraktSentimentsTranslation {
    /// The start of every aspect's translation key, so a screen knows which changes are its aspects'.
    package static let prefix = "aspect."

    /// The aspect's words as the screen shows them.
    package static func text(_ aspect: TraktSentiments.Aspect) -> String {
        guard TranslationPreferences.translatesAutomatically else { return aspect.text }
        let shown = TranslationCenter.shared.presentation(key: prefix + aspect.text, text: aspect.text, hint: "en")
        guard shown.showsTranslation, let translation = shown.translation else { return aspect.text }
        return TraktCommentText(translation).plainText
    }
}
