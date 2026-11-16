import CrucibleCore
import Foundation
import NaturalLanguage

/// The language a piece of text is written in, read on the device.
package enum LanguageDetector {
    /// Below this many letters a guess leans on the hint the source gave, since a few words can pass for several languages.
    private static let shortText = 20

    /// The language `text` is written in, as a Translation identifier, when it is clear enough to act on: the recognizer's
    /// guess when it is confident, else `hint`, the language the source says the text is in, else nil.
    package static func language(of text: String, hint: String? = nil) -> String? {
        let letters = text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        guard letters > 0 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let normalizedHint = hint.flatMap(normalized)
        if let best = hypotheses.max(by: { $0.value < $1.value }), best.key != .undetermined {
            let guess = normalized(best.key.rawValue)
            if letters >= shortText, best.value >= 0.6 { return guess }
            if best.value >= 0.9, letters >= 6 { return guess }
        }
        return normalizedHint
    }

    /// Whether `text` needs translating into `target`: its language is known and is not the target's.
    package static func needsTranslation(_ text: String, hint: String?, into target: String) -> String? {
        guard let source = language(of: text, hint: hint), !TranslationLanguages.isSame(source, target) else { return nil }
        return source
    }

    /// An identifier Translation reads, from one the recognizer or a service wrote: "zh-Hans", "pt", "nb".
    private static func normalized(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty, trimmed.lowercased() != "und" else { return nil }
        return TranslationLanguages.catalogLanguage(for: trimmed) ?? trimmed
    }
}
