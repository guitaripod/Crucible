import CrucibleCore
import Foundation

/// Whether text can be translated from one language into another on this device right now.
package enum TranslationReadiness: Equatable, Sendable {
    case ready
    /// The device translates between them once the person agrees to download the languages.
    case needsDownload
    case unsupported
}

/// Why a translation gave nothing.
package enum TranslationFailure: Error, Equatable, Sendable {
    /// The languages are not on the device yet.
    case notInstalled
    case unsupported
    /// The model would not translate what it was given.
    case declined
    case failed
}

/// A translator on the device: Apple's Translation on iPhone and iPad, the Apple Intelligence model on Apple TV.
package protocol TextTranslating: Sendable {
    func readiness(from source: String, to target: String) async -> TranslationReadiness

    /// Each line in `target`, with its quote, its break and, as far as the translator keeps them, its spoilers, emphasis
    /// and links. Lines without words come back as they were.
    func translate(_ lines: [TraktCommentText.Line], from source: String, to target: String) async throws(TranslationFailure) -> [TraktCommentText.Line]
}

extension TextTranslating {
    /// Comment text in Trakt's markup, translated and back in that markup.
    package func translate(markup: String, from source: String, to target: String) async throws(TranslationFailure) -> String {
        let lines = try await translate(TraktCommentText(markup).lines, from: source, to: target)
        return TraktCommentText.markup(lines)
    }
}

/// The pieces of a line a translator that only reads plain text is given: the runs joined while their spoiler mark stays
/// the same, without emphasis, and the whitespace and emoji at their ends kept aside so a translation sits back in place
/// with them, as a model may drop an emoji it was given. Links and code are never sent; they stay where they were.
struct PlainSegments {
    struct Segment {
        let line: Int
        let isSpoiler: Bool
        let leading: String
        let text: String
        let trailing: String
    }

    /// A part of a line: a segment to translate, or a run kept as it is.
    enum Piece {
        case segment(Int)
        case kept(TraktCommentText.Run)
    }

    let lines: [TraktCommentText.Line]
    let segments: [Segment]
    private let pieces: [Int: [Piece]]

    init(_ lines: [TraktCommentText.Line]) {
        self.lines = lines
        var segments: [Segment] = []
        var pieces: [Int: [Piece]] = [:]
        for (index, line) in lines.enumerated() where line.hasWords {
            var linePieces: [Piece] = []
            var current: (isSpoiler: Bool, text: String)?
            func flush() {
                guard let piece = current else { return }
                current = nil
                let leading = String(piece.text.prefix(while: Self.keptAside))
                let rest = piece.text.dropFirst(leading.count)
                let trailing = String(rest.reversed().prefix(while: Self.keptAside).reversed())
                linePieces.append(.segment(segments.count))
                segments.append(Segment(line: index, isSpoiler: piece.isSpoiler, leading: leading, text: String(rest.dropLast(trailing.count)), trailing: trailing))
            }
            for run in line.runs {
                if run.link != nil || run.styles.contains(.code) {
                    flush()
                    linePieces.append(.kept(run))
                } else if current?.isSpoiler == run.isSpoiler {
                    current?.text += run.text
                } else {
                    flush()
                    current = (run.isSpoiler, run.text)
                }
            }
            flush()
            pieces[index] = linePieces
        }
        self.segments = segments
        self.pieces = pieces
    }

    /// The lines translated by `engine`, which is given the segments that hold a letter, in order, and must answer each.
    func translated(by engine: ([String]) async throws(TranslationFailure) -> [String]) async throws(TranslationFailure) -> [TraktCommentText.Line] {
        let wanted = segments.indices.filter { segments[$0].text.contains { $0.isLetter } }
        guard !wanted.isEmpty else { return lines }
        let answers = try await engine(wanted.map { segments[$0].text })
        guard answers.count == wanted.count else { throw .failed }
        var translations = segments.map(\.text)
        for (index, answer) in zip(wanted, answers) { translations[index] = Self.oneLine(answer) }
        return lines(with: translations)
    }

    /// The lines with each segment's translation in place and every kept run where it was. A line without words is left
    /// as it was.
    func lines(with translations: [String]) -> [TraktCommentText.Line] {
        var result = lines
        for (line, linePieces) in pieces {
            result[line].runs = linePieces.compactMap { piece in
                switch piece {
                case .kept(let run):
                    return run
                case .segment(let index):
                    let segment = segments[index]
                    let words = translations[index]
                    guard !(segment.leading + words + segment.trailing).isEmpty else { return nil }
                    return TraktCommentText.Run(text: segment.leading + words + segment.trailing, isSpoiler: segment.isSpoiler)
                }
            }
        }
        return result
    }

    /// Whether a character at a segment's end stays out of the translation: a space or an emoji.
    static func keptAside(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        let scalars = character.unicodeScalars
        if scalars.contains(where: \.properties.isEmojiPresentation) { return true }
        return scalars.count > 1 && scalars.first?.properties.isEmoji == true
    }

    /// A translation on one line, as the line it replaces was.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
