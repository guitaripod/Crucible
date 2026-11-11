import Foundation
import MidgarCore

/// A subtitle the server found for a title in an online catalogue, not yet downloaded.
package struct PlexSubtitleCandidate: Decodable, Sendable, Hashable, Identifiable {
    package let key: String
    package let codec: String?
    package let format: String?
    package let language: String?
    package let languageCode: String?
    package let providerTitle: String?
    package let title: String?
    package let score: Double
    package let hearingImpaired: Bool
    package let forced: Bool
    package let perfectMatch: Bool

    package var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, codec, format, language, languageCode, providerTitle, title, displayTitle, score, hearingImpaired, forced, perfectMatch
    }

    package init(
        key: String, codec: String? = "srt", format: String? = "srt", language: String? = nil, languageCode: String? = nil,
        providerTitle: String? = nil, title: String? = nil, score: Double = 0, hearingImpaired: Bool = false, forced: Bool = false,
        perfectMatch: Bool = false
    ) {
        self.key = key
        self.codec = codec
        self.format = format
        self.language = language
        self.languageCode = languageCode
        self.providerTitle = providerTitle
        self.title = title
        self.score = score
        self.hearingImpaired = hearingImpaired
        self.forced = forced
        self.perfectMatch = perfectMatch
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func flag(_ key: CodingKeys) -> Bool {
            if let value = (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return value }
            return (PlexNumber.decode(container, key, Int.self) ?? 0) != 0
        }
        key = try container.decode(String.self, forKey: .key)
        codec = string(.codec)
        format = string(.format)
        language = string(.language)
        languageCode = string(.languageCode)
        providerTitle = string(.providerTitle)
        title = string(.title) ?? string(.displayTitle)
        score = PlexNumber.decode(container, .score, Double.self) ?? 0
        hearingImpaired = flag(.hearingImpaired)
        forced = flag(.forced)
        perfectMatch = flag(.perfectMatch)
    }
}

package struct PlexSubtitleSearchResponse: Decodable, Sendable {
    package struct Container: Decodable, Sendable {
        package let Stream: [PlexSubtitleCandidate]?
    }

    package let MediaContainer: Container
}

/// Finds subtitles for a title online through the server and asks it to keep one.
package enum SubtitleSearch {
    /// The server's matches for `ratingKey` in `language` (a two letter code), the best first: perfect matches, then by score.
    package static func search(
        ratingKey: String,
        language: String,
        hearingImpaired: Bool = false,
        forced: Bool = false,
        api: APIClient
    ) async throws -> [PlexSubtitleCandidate] {
        let response: PlexSubtitleSearchResponse = try await api.request(
            .searchSubtitles(ratingKey: ratingKey, language: language, hearingImpaired: hearingImpaired, forced: forced)
        )
        return (response.MediaContainer.Stream ?? []).sorted { lhs, rhs in
            if lhs.perfectMatch != rhs.perfectMatch { return lhs.perfectMatch }
            return lhs.score > rhs.score
        }
    }

    /// The query that tells the server which found subtitle to keep.
    package static func downloadQuery(for candidate: PlexSubtitleCandidate, language: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "key", value: candidate.key),
            URLQueryItem(name: "codec", value: candidate.codec ?? "srt"),
            URLQueryItem(name: "format", value: candidate.format ?? candidate.codec ?? "srt"),
            URLQueryItem(name: "forced", value: candidate.forced ? "1" : "0"),
            URLQueryItem(name: "hearingImpaired", value: candidate.hearingImpaired ? "1" : "0"),
            URLQueryItem(name: "language", value: candidate.languageCode ?? language),
            URLQueryItem(name: "providerTitle", value: candidate.providerTitle ?? ""),
        ]
    }

    /// Has the server download `candidate` and attach it to the title, then forgets the cached metadata so the next load lists it.
    package static func download(_ candidate: PlexSubtitleCandidate, ratingKey: String, language: String, api: APIClient) async throws {
        do {
            try await api.requestConfirmed(.downloadSubtitle(ratingKey: ratingKey, query: downloadQuery(for: candidate, language: language)))
            await api.invalidate(ratingKey: ratingKey)
        } catch {
            MidgarLog.error("Subtitle download for ratingKey=\(ratingKey) failed: \(error.localizedDescription)", category: .networking)
            throw error
        }
    }

    /// What a candidate says about itself: its provider and the marks that matter, e.g. "OpenSubtitles · Perfect match · SDH".
    package static func detail(_ candidate: PlexSubtitleCandidate) -> String {
        var parts: [String] = []
        if let provider = candidate.providerTitle, !provider.isEmpty { parts.append(provider) }
        if candidate.perfectMatch { parts.append(String(localized: "Perfect match", comment: "A subtitle found online that is made for exactly this release")) }
        if candidate.hearingImpaired { parts.append(String(localized: "SDH", comment: "Subtitles for the deaf and hard of hearing")) }
        if candidate.forced { parts.append(String(localized: "Forced", comment: "Subtitle track flagged as forced")) }
        return parts.joined(separator: " · ")
    }

    package static let title = String(localized: "Search for Subtitles…", comment: "Menu item that looks for subtitles online")
    package static let screenTitle = String(localized: "Subtitles", comment: "Menu title for the subtitle options")
    package static let emptyTitle = String(localized: "No Subtitles Found", comment: "Title when the online subtitle search found nothing")
    package static let emptyText = String(localized: "Try another language, or check that the server can search for subtitles.", comment: "Message when the online subtitle search found nothing")
    package static let languageTitle = String(localized: "Language", comment: "Title of the choice of subtitle language")
}

/// The languages offered for an online subtitle search.
package enum SubtitleLanguages {
    package static let codes = [
        "en", "fi", "sv", "no", "da", "is", "de", "fr", "es", "pt", "it", "nl", "pl", "cs", "hu", "ro", "el", "tr", "ru", "uk",
        "ar", "he", "hi", "th", "vi", "id", "ja", "ko", "zh",
    ]

    /// The viewer's first preferred language when it is on the list, else English.
    package static func defaultCode(preferred: [String] = Locale.preferredLanguages) -> String {
        for identifier in preferred {
            let raw = String(identifier.prefix { $0 != "-" && $0 != "_" }).lowercased()
            let code = raw == "nb" || raw == "nn" ? "no" : raw
            if codes.contains(code) { return code }
        }
        return "en"
    }

    /// The language's own name in the interface language.
    package static func name(for code: String) -> String {
        Formatters.interfaceLocale.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}
