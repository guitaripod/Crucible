import AVFoundation
import Foundation

/// The subtitle and audio choices made on one item, carried to the item that replaces it. A transcode
/// that is rebuilt (after a return, a heal or a far jump) is a new item, and the system player would pick
/// its subtitles afresh, turning on subtitles the viewer had turned off.
struct MediaSelectionCarry: Sendable {
    private enum Choice: Sendable {
        case off
        case option(language: String?, name: String)
    }

    private var choices: [AVMediaCharacteristic: Choice] = [:]

    static let empty = MediaSelectionCarry()

    /// Reads what `item` has selected for subtitles and audio.
    @MainActor
    static func capture(from item: AVPlayerItem?) async -> MediaSelectionCarry {
        guard let item else { return .empty }
        var carry = MediaSelectionCarry()
        for characteristic in [AVMediaCharacteristic.legible, .audible] {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                carry.choices[characteristic] = .option(language: selected.extendedLanguageTag, name: selected.displayName)
            } else if characteristic == .legible {
                carry.choices[characteristic] = .off
            }
        }
        return carry
    }

    /// Selects the same choices on `item`: no subtitles if they were off, otherwise the option with the
    /// same language and name. A choice the new item does not offer is left to the player.
    @MainActor
    func apply(to item: AVPlayerItem) async {
        for (characteristic, choice) in choices {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            switch choice {
            case .off:
                if group.allowsEmptySelection { item.select(nil, in: group) }
            case .option(let language, let name):
                let match = group.options.first { $0.extendedLanguageTag == language && $0.displayName == name }
                    ?? group.options.first { $0.extendedLanguageTag == language }
                if let match { item.select(match, in: group) }
            }
        }
    }
}
