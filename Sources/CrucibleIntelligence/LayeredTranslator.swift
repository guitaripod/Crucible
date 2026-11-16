import CrucibleCore
import Foundation

/// Apple's Translation first, and where it cannot translate a pair the Apple Intelligence model on the device, which
/// writes some languages Translation has not installed and runs where Translation does not.
struct LayeredTranslator: TextTranslating {
    let first: any TextTranslating
    let second: any TextTranslating

    func readiness(from source: String, to target: String) async -> TranslationReadiness {
        let primary = await first.readiness(from: source, to: target)
        guard primary != .ready else { return .ready }
        return await second.readiness(from: source, to: target) == .ready ? .ready : primary
    }

    func translate(_ lines: [TraktCommentText.Line], from source: String, to target: String) async throws(TranslationFailure) -> [TraktCommentText.Line] {
        if await first.readiness(from: source, to: target) != .ready, await second.readiness(from: source, to: target) == .ready {
            return try await second.translate(lines, from: source, to: target)
        }
        return try await first.translate(lines, from: source, to: target)
    }
}
