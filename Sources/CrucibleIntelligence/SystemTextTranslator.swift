#if canImport(Translation) && !os(tvOS)
import CrucibleCore
import Foundation
import MidgarCore
import Translation

/// Apple's Translation on iPhone, iPad and Mac. From iOS 26.4 it asks for Apple Intelligence's models, which translate
/// with more of the sense and keep a line's spoilers, emphasis and links in place; before that it uses the traditional
/// models, one plain piece of a line at a time.
@available(iOS 26.0, macOS 26.0, *)
package struct SystemTextTranslator: TextTranslating {
    package init() {}

    package func readiness(from source: String, to target: String) async -> TranslationReadiness {
        let status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        switch status {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Every language the device translates into, as Translation names them.
    package static func supportedLanguages() async -> [String] {
        await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
    }

    package func translate(_ lines: [TraktCommentText.Line], from source: String, to target: String) async throws(TranslationFailure) -> [TraktCommentText.Line] {
        let session = makeSession(from: source, to: target)
        if #available(iOS 26.4, macOS 26.4, *) {
            return try await translateStyled(lines, session: session)
        }
        return try await PlainSegments(lines).translated { texts throws(TranslationFailure) in
            let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            return try await Self.responses(to: requests, in: session).map(\.targetText)
        }
    }

    private var availability: LanguageAvailability {
        if #available(iOS 26.4, macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .highFidelity) }
        return LanguageAvailability()
    }

    private func makeSession(from source: String, to target: String) -> TranslationSession {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        if #available(iOS 26.4, macOS 26.4, *) { return TranslationSession(installedSource: from, target: to, preferredStrategy: .highFidelity) }
        return TranslationSession(installedSource: from, target: to)
    }

    /// Each line with words translated on its own as styled text, so a sentence keeps its sense across a bold word or a
    /// link; batches lose the styles, so the lines go one by one. A line with a hidden spoiler is translated a piece at a
    /// time instead, each spoiler on its own, because a style is kept only as far as Translation can and a spoiler that
    /// slipped its cover would give the story away.
    @available(iOS 26.4, macOS 26.4, *)
    private func translateStyled(_ lines: [TraktCommentText.Line], session: TranslationSession) async throws(TranslationFailure) -> [TraktCommentText.Line] {
        var result = lines
        for index in lines.indices where lines[index].hasWords {
            if lines[index].runs.contains(where: \.isSpoiler) {
                let translated = try await PlainSegments([lines[index]]).translated { texts throws(TranslationFailure) in
                    let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    return try await Self.responses(to: requests, in: session).map(\.targetText)
                }
                result[index].runs = translated[0].runs
                continue
            }
            let response: TranslationSession.Response
            do {
                response = try await session.translate(StyledLine.attributed(lines[index]))
            } catch {
                throw Self.failure(error)
            }
            result[index].runs = StyledLine.runs(response.attributedTargetText ?? AttributedString(response.targetText))
        }
        return result
    }

    private static func responses(to requests: [TranslationSession.Request], in session: TranslationSession) async throws(TranslationFailure) -> [TranslationSession.Response] {
        do {
            return try await session.translations(from: requests)
        } catch {
            throw failure(error)
        }
    }

    private static func failure(_ error: any Error) -> TranslationFailure {
        MidgarLog.notice("Translation refused: \(error.localizedDescription)", category: .lifecycle)
        if TranslationError.notInstalled ~= error { return .notInstalled }
        if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error { return .unsupported }
        return .failed
    }
}

/// A line of comment runs as the attributed text Translation keeps styles on, and back.
@available(iOS 26.4, macOS 26.4, *)
enum StyledLine {
    enum SpoilerAttribute: AttributedStringKey {
        typealias Value = Bool
        static let name = "CrucibleSpoiler"
    }

    static func attributed(_ line: TraktCommentText.Line) -> AttributedString {
        var result = AttributedString()
        for run in line.runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.styles.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.styles.contains(.italic) { intent.insert(.emphasized) }
            if run.styles.contains(.strike) { intent.insert(.strikethrough) }
            if run.styles.contains(.code) { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let url = run.link { piece.link = url }
            if run.styles.contains(.code) || run.link?.absoluteString == run.text { piece.skipsTranslation = true }
            if run.isSpoiler { piece[SpoilerAttribute.self] = true }
            result += piece
        }
        return result
    }

    /// The runs of a translated line, joined where their styles match, on one line as the source was.
    static func runs(_ text: AttributedString) -> [TraktCommentText.Run] {
        var runs: [TraktCommentText.Run] = []
        for run in text.runs {
            let piece = String(text[run.range].characters).replacingOccurrences(of: "\n", with: " ")
            guard !piece.isEmpty else { continue }
            var styles: Set<TraktCommentText.Style> = []
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { styles.insert(.bold) }
            if intent.contains(.emphasized) { styles.insert(.italic) }
            if intent.contains(.strikethrough) { styles.insert(.strike) }
            if intent.contains(.code) { styles.insert(.code) }
            if let url = run.link { styles.insert(.link(url)) }
            let isSpoiler = run[SpoilerAttribute.self] ?? false
            if let last = runs.last, last.styles == styles, last.isSpoiler == isSpoiler {
                runs[runs.count - 1].text += piece
            } else {
                runs.append(TraktCommentText.Run(text: piece, styles: styles, isSpoiler: isSpoiler))
            }
        }
        return runs
    }
}
#endif
