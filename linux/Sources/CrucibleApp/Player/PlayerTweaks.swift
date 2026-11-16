import CrucibleCore
import Foundation

/// What the viewer set on the picture, the sound and the subtitles beyond the tracks. A title keeps what belongs to its
/// file (sync and framing); the rest is taste and holds for every title.
struct PlayerTweaks: Equatable {
    /// What one title keeps: the sync of its sound and subtitles, how its picture fills the screen, and whether it needs
    /// deinterlacing.
    struct Title: Codable, Equatable {
        var audioDelay: Double = 0
        var subtitleDelay: Double = 0
        var framing: Framing = .original
        var zoom: Double = 0
        var rotation: Int = 0
        var deinterlace = false
    }

    /// What holds for every title.
    struct Taste: Codable, Equatable {
        var subtitleStyle: SubtitleStyle = .outline
        var subtitlePosition: Int = 100
        var dialogue: Dialogue = .off
        var volumeBoost = false
        var brightness = 0
        var contrast = 0
        var saturation = 0
        var gamma = 0
        /// Turn subtitles on while the sound is muted.
        var subtitlesWhenMuted = true
    }

    /// How the picture fills the view: as made, cropped to fill it, stretched to it, or as another shape.
    enum Framing: String, Codable, CaseIterable {
        case original, fill, stretch, wide, standard, scope

        /// The aspect mpv is told to use instead of the file's, when the framing forces one.
        var aspect: String? {
            switch self {
            case .wide: "16:9"
            case .standard: "4:3"
            case .scope: "2.39:1"
            case .original, .fill, .stretch: nil
            }
        }
    }

    enum SubtitleStyle: String, Codable, CaseIterable {
        case outline, shadow, box
    }

    /// Dialogue processing: none, speech lifted against everything else, or loud passages brought down for late nights.
    enum Dialogue: String, Codable, CaseIterable {
        case off, clearSpeech, night

        /// The audio filter mpv runs for it.
        var filter: String {
            switch self {
            case .off: ""
            case .clearSpeech: "lavfi=[speechnorm=e=6.25:r=0.00001:l=1]"
            case .night: "lavfi=[dynaudnorm=f=250:g=15:p=0.9:m=8]"
            }
        }
    }

    var title = Title()
    var taste = Taste()
}

/// Keeps `PlayerTweaks`: taste under one key, and each title's own in a map keyed by server and title, holding the titles
/// changed last (`titleCapacity`) and dropping a title whose settings went back to the defaults.
@MainActor
enum PlayerTweakStore {
    private static let tasteKey = "player.taste"
    private static let titlesKey = "player.titles"
    private static let titleCapacity = 400

    private struct Kept: Codable {
        var title: PlayerTweaks.Title
        var changed: Date
    }

    static func taste(in defaults: UserDefaults = .standard) -> PlayerTweaks.Taste {
        defaults.data(forKey: tasteKey).flatMap { try? JSONDecoder().decode(PlayerTweaks.Taste.self, from: $0) } ?? PlayerTweaks.Taste()
    }

    static func save(_ taste: PlayerTweaks.Taste, in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(taste), forKey: tasteKey)
    }

    static func title(_ key: String, in defaults: UserDefaults = .standard) -> PlayerTweaks.Title {
        titles(in: defaults)[key]?.title ?? PlayerTweaks.Title()
    }

    static func save(_ title: PlayerTweaks.Title, for key: String, in defaults: UserDefaults = .standard) {
        var all = titles(in: defaults)
        if title == PlayerTweaks.Title() {
            all[key] = nil
        } else {
            all[key] = Kept(title: title, changed: Date())
        }
        if all.count > titleCapacity {
            for stale in all.sorted(by: { $0.value.changed < $1.value.changed }).prefix(all.count - titleCapacity) { all[stale.key] = nil }
        }
        defaults.set(try? JSONEncoder().encode(all), forKey: titlesKey)
    }

    /// The key a title's settings are kept under: the server it is on and its rating key.
    static func key(ratingKey: String) -> String {
        "\(ServerBootstrap.savedMachineIdentifier ?? "")/\(ratingKey)"
    }

    private static func titles(in defaults: UserDefaults) -> [String: Kept] {
        defaults.data(forKey: titlesKey).flatMap { try? JSONDecoder().decode([String: Kept].self, from: $0) } ?? [:]
    }
}
