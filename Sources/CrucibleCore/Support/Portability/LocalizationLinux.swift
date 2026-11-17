#if !canImport(Darwin)
import Foundation

extension String {
    /// Linux stand-in for Foundation's `String.LocalizationValue`: the literal becomes the catalog key with `%@`, `%lld`,
    /// `%llu` or `%lf` where values were interpolated, the way Xcode extracts it into `Localizable.xcstrings`.
    package struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
        package enum Argument: Sendable {
            case object(String)
            case integer(Int64)
            case unsigned(UInt64)
            case double(Double)
        }

        package var key: String
        package var arguments: [Argument]

        package init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        package init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        package struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [Argument] = []

            package init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity + interpolationCount * 4)
            }

            /// A literal `%` between interpolations is `%%` in the key, as Xcode writes it into the catalog for a string
            /// with values in it ("%lld%% match"); a plain literal keeps its `%` as is.
            package mutating func appendLiteral(_ literal: String) {
                key += literal.replacingOccurrences(of: "%", with: "%%")
            }

            package mutating func appendInterpolation(_ value: String) {
                key += "%@"
                arguments.append(.object(value))
            }

            package mutating func appendInterpolation<T: BinaryInteger>(_ value: T) {
                if T.isSigned {
                    key += "%lld"
                    arguments.append(.integer(Int64(value)))
                } else {
                    key += "%llu"
                    arguments.append(.unsigned(UInt64(value)))
                }
            }

            package mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T) {
                key += "%lf"
                arguments.append(.double(Double(value)))
            }

            package mutating func appendInterpolation<T>(_ value: T) {
                key += "%@"
                arguments.append(.object(String(describing: value)))
            }
        }
    }

    package init(localized value: LocalizationValue, comment: StaticString? = nil) {
        self = LocalizationCatalog.shared.string(key: value.key, fallback: value.key, arguments: value.arguments)
    }

    package init(localized key: StaticString, defaultValue: LocalizationValue, comment: StaticString? = nil) {
        self = LocalizationCatalog.shared.string(key: "\(key)", fallback: defaultValue.key, arguments: defaultValue.arguments)
    }
}

/// The app's string catalog on Linux, read from the same `Localizable.xcstrings` Xcode compiles for the Apple apps. Without
/// a catalog every string is its key with the values filled in, as on an Apple test host.
package final class LocalizationCatalog: @unchecked Sendable {
    package static let shared = LocalizationCatalog()

    private struct Entry {
        var value: String?
        var plural: [String: String]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var language = "en"

    /// Loads the catalog for the first of `preferredLanguages` it has (by language, script and region), English otherwise.
    package func load(xcstrings data: Data, preferredLanguages: [String] = Locale.preferredLanguages) throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let available = Set(catalog.strings.values.flatMap { $0.localizations?.keys.map { $0 } ?? [] })
        let chosen = Self.match(preferredLanguages, in: available) ?? catalog.sourceLanguage
        var loaded: [String: Entry] = [:]
        for (key, string) in catalog.strings {
            guard let localization = string.localizations?[chosen] else { continue }
            let plural = localization.variations?.plural?.compactMapValues { $0.stringUnit.value } ?? [:]
            loaded[key] = Entry(value: localization.stringUnit?.value, plural: plural)
        }
        lock.lock()
        entries = loaded
        language = chosen
        lock.unlock()
    }

    /// Adds a second catalog's strings in the language the first one loaded in, English where it lacks that language:
    /// strings one platform keeps in a catalog of its own, out of the one the Apple apps ship.
    package func add(xcstrings data: Data) throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let chosen = currentLanguage
        var added: [String: Entry] = [:]
        for (key, string) in catalog.strings {
            guard let localization = string.localizations?[chosen] ?? string.localizations?[catalog.sourceLanguage] else { continue }
            let plural = localization.variations?.plural?.compactMapValues { $0.stringUnit.value } ?? [:]
            added[key] = Entry(value: localization.stringUnit?.value, plural: plural)
        }
        lock.lock()
        entries.merge(added) { _, new in new }
        lock.unlock()
    }

    package var currentLanguage: String {
        lock.lock()
        defer { lock.unlock() }
        return language
    }

    func string(key: String, fallback: String, arguments: [String.LocalizationValue.Argument]) -> String {
        lock.lock()
        let entry = entries[key]
        let language = language
        lock.unlock()
        var template = entry?.value ?? fallback
        if let entry, !entry.plural.isEmpty, let count = arguments.firstCount {
            let category = PluralRules.category(for: count, language: language)
            template = entry.plural[category] ?? entry.plural["other"] ?? template
        }
        guard !arguments.isEmpty else { return template }
        return Self.format(template, arguments: arguments, locale: Locale(identifier: language))
    }

    /// Fills `%@`, `%lld`, `%llu`, `%d`, `%u`, `%lf` and `%f` (with `n$` positions and a precision) from the arguments,
    /// turns `%%` into `%`, and leaves every other `%` as text, so "87% critics" survives the way Apple's runtime keeps it.
    static func format(_ template: String, arguments: [String.LocalizationValue.Argument], locale: Locale) -> String {
        var output = ""
        var next = 0
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            guard character == "%" else {
                output.append(character)
                index = template.index(after: index)
                continue
            }
            let rest = template[template.index(after: index)...]
            if rest.first == "%" {
                output.append("%")
                index = template.index(index, offsetBy: 2)
                continue
            }
            guard let match = rest.prefixMatch(of: /(?:(\d+)\$)?(\.\d+)?(@|lld|llu|ld|lu|d|u|lf|f)/) else {
                output.append("%")
                index = template.index(after: index)
                continue
            }
            let position = match.1.flatMap { Int($0) }.map { $0 - 1 } ?? next
            next = position + 1
            if arguments.indices.contains(position) {
                output += Self.text(of: arguments[position], precision: match.2.map(String.init), locale: locale)
            }
            index = match.range.upperBound
        }
        return output
    }

    private static func text(of argument: String.LocalizationValue.Argument, precision: String?, locale: Locale) -> String {
        switch argument {
        case .object(let value): value
        case .integer(let value): String(value)
        case .unsigned(let value): String(value)
        case .double(let value): String(format: "%\(precision ?? "")f", locale: locale, value)
        }
    }

    private static func match(_ preferred: [String], in available: Set<String>) -> String? {
        for identifier in preferred {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            if available.contains(normalized) { return normalized }
            let parts = normalized.split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                let traditional = parts.contains("Hant") || parts.contains("TW") || parts.contains("HK") || parts.contains("MO")
                let candidate = traditional ? "zh-Hant" : "zh-Hans"
                if available.contains(candidate) { return candidate }
            }
            if base == "pt", available.contains("pt-BR") { return "pt-BR" }
            if base == "no" || base == "nn", available.contains("nb") { return "nb" }
            if available.contains(base) { return base }
        }
        return nil
    }

    private struct Catalog: Decodable {
        var sourceLanguage: String
        var strings: [String: CatalogString]
    }

    private struct CatalogString: Decodable {
        var localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        var stringUnit: StringUnit?
        var variations: Variations?
    }

    private struct Variations: Decodable {
        var plural: [String: PluralCase]?
    }

    private struct PluralCase: Decodable {
        var stringUnit: StringUnit
    }

    private struct StringUnit: Decodable {
        var value: String?
    }
}

extension [String.LocalizationValue.Argument] {
    var firstCount: Int64? {
        for argument in self {
            switch argument {
            case .integer(let number): return number
            case .unsigned(let number): return Int64(clamping: number)
            default: continue
            }
        }
        return nil
    }
}

/// CLDR plural categories for whole numbers in the languages Crucible ships.
package enum PluralRules {
    package static func category(for count: Int64, language: String) -> String {
        let n = Swift.abs(count)
        let base = language.split(separator: "-").first.map(String.init) ?? language
        switch base {
        case "ja", "ko", "zh":
            return "other"
        case "fr", "pt":
            if n == 0 || n == 1 { return "one" }
            return n % 1_000_000 == 0 ? "many" : "other"
        case "es", "it":
            if n == 1 { return "one" }
            return n % 1_000_000 == 0 ? "many" : "other"
        case "pl":
            if n == 1 { return "one" }
            let lastDigit = n % 10
            let lastTwo = n % 100
            if (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) { return "few" }
            return "many"
        case "is":
            return n % 10 == 1 && n % 100 != 11 ? "one" : "other"
        default:
            return n == 1 ? "one" : "other"
        }
    }
}
#endif
