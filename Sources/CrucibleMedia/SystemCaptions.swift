import Foundation
import MediaAccessibility

/// The viewer's caption setting in Settings, Accessibility, Subtitles and Captioning. The player's own automatic subtitle
/// selection is off (it undid the app's choice the moment an item became ready), so the app applies this setting itself.
package enum SystemCaptions {
    /// The device's language when captions are set to always on, else nil: a subtitle in it is picked when nothing else picks one.
    package static var alwaysOnLanguage: String? {
        guard MACaptionAppearanceGetDisplayType(.user) == .alwaysOn else { return nil }
        return Locale.preferredLanguages.first
    }
}
