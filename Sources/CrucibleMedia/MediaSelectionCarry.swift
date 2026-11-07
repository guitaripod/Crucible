import AVFoundation
import Foundation

/// The audio choice made on one item, carried to the item that replaces it. A transcode that is rebuilt (after a return, a heal
/// or a far jump) is a new item, and the system player would pick its audio afresh. Subtitles are not carried here: the session
/// sets them on every item it plays (`syncSubtitles(on:)`).
struct MediaSelectionCarry: Sendable {
    private var audio: (language: String?, name: String)?

    static let empty = MediaSelectionCarry()

    /// Reads what `item` has selected for audio.
    @MainActor
    static func capture(from item: AVPlayerItem?) async -> MediaSelectionCarry {
        guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return .empty }
        return MediaSelectionCarry(audio: (selected.extendedLanguageTag, selected.displayName))
    }

    /// Selects the same audio on `item`: the option with the same language and name, else the same language. A choice the new
    /// item does not offer is left to the player.
    @MainActor
    func apply(to item: AVPlayerItem) async {
        guard let audio, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        let match = group.options.first { $0.extendedLanguageTag == audio.language && $0.displayName == audio.name }
            ?? group.options.first { $0.extendedLanguageTag == audio.language }
        if let match { item.select(match, in: group) }
    }
}
