import Foundation
import MidgarCore
#if canImport(os)
import os
#endif

/// The languages Crucible can translate comments, reviews and descriptions into, and the one it translates into. The
/// device decides what is possible: iPhone and iPad translate on device with Apple's Translation, an Apple TV with
/// Apple Intelligence uses its on-device model, and where neither runs the list is empty and nothing offers a translation.
package enum TranslationLanguages {
    /// Every language a device might translate into, in the identifiers Translation uses: each is offered only when the
    /// device reports it at launch.
    package static let catalog = [
        "ar", "da", "de", "en", "es", "fi", "fr", "he", "hi", "id", "it", "ja", "ko", "ms", "nb", "nl",
        "pl", "pt", "ru", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]

    private static let offered = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// The catalog's languages this device translates into, empty until the app reports them and on a device that
    /// cannot translate at all.
    package static var available: [String] { offered.withLock { $0 } }

    /// Whether this device translates at all, which every translation control and setting waits for.
    package static var isAvailable: Bool { !available.isEmpty }

    /// Records what the device translates into: the catalog's languages that match one of `supported`, in catalog order.
    package static func setSupported(_ supported: [String]) {
        let matched = catalog.filter { language in supported.contains { isSame($0, language) } }
        offered.withLock { $0 = matched }
    }

    /// Whether two identifiers name the same written language: the same language and script, whatever the region, so
    /// "pt-BR" and "pt" match while "zh-Hans" and "zh-Hant" do not.
    package static func isSame(_ first: String, _ second: String) -> Bool {
        let a = Locale.Language(identifier: first)
        let b = Locale.Language(identifier: second)
        guard let codeA = a.languageCode?.identifier, let codeB = b.languageCode?.identifier else { return false }
        guard normalizedCode(codeA) == normalizedCode(codeB) else { return false }
        return a.maximalIdentifierScript == b.maximalIdentifierScript
    }

    /// The catalog language `identifier` falls under, or nil when it is none of them.
    package static func catalogLanguage(for identifier: String) -> String? {
        catalog.first { isSame($0, identifier) }
    }

    /// The language's own name in the language of the app, "Spanish" or "Chinese, Traditional".
    package static func name(_ identifier: String, in locale: Locale = .autoupdatingCurrent) -> String {
        let name = locale.localizedString(forIdentifier: identifier) ?? identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Norwegian is written as Bokmål everywhere Crucible reads it.
    private static func normalizedCode(_ code: String) -> String {
        code == "no" ? "nb" : code
    }
}

extension Locale.Language {
    /// The script of the language once filled in from its likely values, "Hans" for "zh" and "Latn" for "pt-BR".
    fileprivate var maximalIdentifierScript: String? {
        Locale.Language(identifier: maximalIdentifier).script?.identifier
    }
}
