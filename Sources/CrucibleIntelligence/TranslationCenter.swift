import CrucibleCore
import Foundation
import MidgarCore

extension Notification.Name {
    /// Posted on the main thread when a text's translation changed: it started, finished, failed, or the reader switched
    /// between it and the original. The object is the text's key.
    package static let translationChanged = Notification.Name("crucible.translationChanged")
}

/// Every translation on the screens: which texts are in another language than the reader's, what each one shows now, and
/// the translations themselves, kept for the session. With Translate Automatically on, a text is translated as it is first
/// shown, wherever the languages are already on the device; otherwise, and whenever a download is needed, it offers
/// Translate instead.
@MainActor
package final class TranslationCenter {
    package static let shared = TranslationCenter()

    /// What a text shows about its translation.
    package enum Phase: Equatable, Sendable {
        /// It is in the reader's language, or the device cannot translate it.
        case none
        /// It can be translated when the reader asks.
        case offer
        case translating
        case translated
        /// The reader chose the original after it was translated.
        case original
        case failed
    }

    /// A text's phase, the language it was written in, and its translation once there is one.
    package struct Presentation: Equatable, Sendable {
        package var phase: Phase
        package var source: String?
        package var translation: String?

        package static let none = Presentation(phase: .none, source: nil, translation: nil)

        /// The source language's name, "Spanish".
        package var sourceName: String? { source.map { TranslationLanguages.name($0) } }

        /// Whether the screen shows the translation instead of the text as written.
        package var showsTranslation: Bool { phase == .translated && translation != nil }
    }

    private struct Entry {
        var source: String
        var phase: Phase
        var translation: String?
    }

    /// The translator, installed at launch where the device can translate.
    package var translator: (any TextTranslating)?
    /// Asks the person to download the languages a translation needs, on iPhone and iPad; true once they are there.
    package var downloadLanguages: (@MainActor (_ source: String, _ target: String) async -> Bool)?

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var readiness: [String: TranslationReadiness] = [:]
    private var sources: [String: String?] = [:]
    private let queue = TranslationQueue()
    private static let keptEntries = 600

    private init() {
        NotificationCenter.default.addObserver(forName: .translationPreferencesChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TranslationCenter.shared.preferencesChanged() }
        }
    }

    /// Whether this device translates at all.
    package var isAvailable: Bool { translator != nil && TranslationLanguages.isAvailable }

    // MARK: - Comments

    /// What a comment shows about its translation, starting it when Translate Automatically is on.
    package func presentation(for comment: TraktComment) -> Presentation {
        presentation(key: Self.key(comment), text: comment.text, hint: comment.language)
    }

    /// The comment as the screen shows it: with its translation in place of its text while that is what the reader sees.
    package func displayed(_ comment: TraktComment) -> TraktComment {
        let shown = presentation(for: comment)
        guard shown.showsTranslation, let translation = shown.translation else { return comment }
        var copy = comment
        copy.text = translation
        return copy
    }

    /// Translates a comment, or shows its translation again: the Translate, Try Again and Show Translation buttons.
    package func translate(_ comment: TraktComment) {
        translate(key: Self.key(comment), text: comment.text, hint: comment.language)
    }

    /// Shows the comment as written, or its translation again.
    package func toggleOriginal(_ comment: TraktComment) {
        toggleOriginal(key: Self.key(comment))
    }

    /// The key a comment's translation is kept under: its id and when it was last edited.
    package static func key(_ comment: TraktComment) -> String {
        "comment.\(comment.id).\(Int(comment.updatedAt?.timeIntervalSince1970 ?? comment.createdAt.timeIntervalSince1970))"
    }

    // MARK: - Any text

    /// What a text shows about its translation, starting it when Translate Automatically is on. `key` names the text and
    /// changes when it does; `hint` is the language its source says it is in.
    package func presentation(key: String, text: String, hint: String? = nil) -> Presentation {
        guard isAvailable, let source = source(of: text, key: key, hint: hint) else { return .none }
        let target = TranslationPreferences.targetLanguage
        guard !TranslationLanguages.isSame(source, target) else { return .none }
        let entryKey = Self.entryKey(key, target: target)
        if let entry = entries[entryKey] {
            return Presentation(phase: entry.phase, source: entry.source, translation: entry.translation)
        }
        let pair = readiness[Self.pairKey(source, target)]
        if pair == .unsupported { return .none }
        guard TranslationPreferences.translatesAutomatically, pair != .needsDownload else {
            return Presentation(phase: .offer, source: source, translation: nil)
        }
        start(entryKey, text: text, source: source, target: target, asked: false, announcing: false)
        return Presentation(phase: .translating, source: source, translation: nil)
    }

    /// Translates a text when the reader asks, downloading its languages first when they need that and the person agrees.
    package func translate(key: String, text: String, hint: String? = nil) {
        guard isAvailable, let source = source(of: text, key: key, hint: hint) else { return }
        let target = TranslationPreferences.targetLanguage
        guard !TranslationLanguages.isSame(source, target) else { return }
        let entryKey = Self.entryKey(key, target: target)
        if let entry = entries[entryKey], entry.phase == .original || entry.phase == .translated {
            if entry.phase == .original { set(entryKey, Entry(source: source, phase: .translated, translation: entry.translation)) }
            return
        }
        guard entries[entryKey]?.phase != .translating else { return }
        start(entryKey, text: text, source: source, target: target, asked: true)
    }

    /// Switches a translated text between its translation and the text as written.
    package func toggleOriginal(key: String) {
        let entryKey = Self.entryKey(key, target: TranslationPreferences.targetLanguage)
        guard var entry = entries[entryKey], entry.translation != nil else { return }
        switch entry.phase {
        case .translated: entry.phase = .original
        case .original: entry.phase = .translated
        default: return
        }
        set(entryKey, entry)
    }

    /// Writing that has to go out in `target` whatever it was written in, such as a comment for Trakt, which takes only
    /// English: the same markup with its words translated, downloading the languages first when the person agrees.
    /// Nil when it is already in `target` or the device cannot translate it.
    package func translateDraft(_ markup: String, into target: String) async throws(TranslationFailure) -> String? {
        guard let translator, let source = LanguageDetector.language(of: TraktCommentText(markup).plainText),
              !TranslationLanguages.isSame(source, target) else { return nil }
        guard try await prepare(source, target, asked: true) else { throw .notInstalled }
        return try await translator.translate(markup: markup, from: source, to: target)
    }

    /// The language a draft is written in, when the device reads it clearly.
    package func language(ofDraft markup: String) -> String? {
        LanguageDetector.language(of: TraktCommentText(markup).plainText)
    }

    // MARK: - Work

    /// Starts a translation. `announcing` is false while a screen is asking for a text's presentation, which already
    /// shows it translating, so no change is posted into the middle of its layout.
    private func start(_ entryKey: String, text: String, source: String, target: String, asked: Bool, announcing: Bool = true) {
        set(entryKey, Entry(source: source, phase: .translating, translation: nil), announcing: announcing)
        Task { [weak self] in
            guard let self else { return }
            do throws(TranslationFailure) {
                guard try await prepare(source, target, asked: asked) else {
                    set(entryKey, Entry(source: source, phase: readiness[Self.pairKey(source, target)] == .unsupported ? .none : .offer, translation: nil))
                    return
                }
                let translation = try await queue.run { [translator] () async throws(TranslationFailure) -> String in
                    guard let translator else { throw .unsupported }
                    return try await translator.translate(markup: text, from: source, to: target)
                }
                set(entryKey, Entry(source: source, phase: .translated, translation: translation))
            } catch {
                if error == .notInstalled { readiness[Self.pairKey(source, target)] = .needsDownload }
                if error == .unsupported { readiness[Self.pairKey(source, target)] = .unsupported }
                let phase: Phase = error == .unsupported ? .none : (error == .notInstalled && !asked ? .offer : .failed)
                set(entryKey, Entry(source: source, phase: phase, translation: nil))
            }
        }
    }

    /// Whether the languages are ready to translate between, asking the person to download them when they asked for the
    /// translation themselves.
    private func prepare(_ source: String, _ target: String, asked: Bool) async throws(TranslationFailure) -> Bool {
        let pair = Self.pairKey(source, target)
        var state = readiness[pair]
        if state == nil || state == .needsDownload {
            state = await translator?.readiness(from: source, to: target) ?? .unsupported
            readiness[pair] = state
        }
        switch state {
        case .ready?: return true
        case .needsDownload?:
            guard asked, let downloadLanguages else { return false }
            guard await downloadLanguages(source, target) else { return false }
            readiness[pair] = .ready
            return true
        default:
            return false
        }
    }

    private func source(of text: String, key: String, hint: String?) -> String? {
        if let known = sources[key] { return known }
        let detected = LanguageDetector.language(of: TraktCommentText(text).plainText, hint: hint)
        if sources.count > Self.keptEntries * 4 { sources.removeAll() }
        sources[key] = detected
        return detected
    }

    private func set(_ entryKey: String, _ entry: Entry, announcing: Bool = true) {
        if entries[entryKey] == nil {
            order.append(entryKey)
            if order.count > Self.keptEntries {
                let dropped = order.removeFirst()
                entries[dropped] = nil
            }
        }
        entries[entryKey] = entry
        guard announcing else { return }
        NotificationCenter.default.post(name: .translationChanged, object: Self.textKey(of: entryKey))
    }

    /// A change of language or of Translate Automatically starts over: what was translated stays kept per language, and
    /// what was waiting to be offered may now translate on its own.
    private func preferencesChanged() {
        readiness = readiness.filter { $0.value == .ready }
        NotificationCenter.default.post(name: .translationChanged, object: nil)
    }

    private static func entryKey(_ key: String, target: String) -> String { "\(target)|\(key)" }

    private static func textKey(of entryKey: String) -> String {
        guard let bar = entryKey.firstIndex(of: "|") else { return entryKey }
        return String(entryKey[entryKey.index(after: bar)...])
    }

    private static func pairKey(_ source: String, _ target: String) -> String { "\(source)>\(target)" }
}

/// Runs translations two at a time, so a screen full of comments does not start dozens of translations at once.
actor TranslationQueue {
    private let width = 2
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<Value: Sendable>(_ work: @Sendable () async throws(TranslationFailure) -> Value) async throws(TranslationFailure) -> Value {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        guard running >= width else {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
