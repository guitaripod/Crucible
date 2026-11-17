import CrucibleCore
import CrucibleWeb
import Foundation

/// What the viewer set for web video (Settings › Web Video), kept with the app's other settings.
enum WebSettings {
    /// The tallest picture picked on its own.
    enum Quality: String, CaseIterable {
        case best, p2160 = "2160", p1440 = "1440", p1080 = "1080", p720 = "720", p480 = "480"

        var maximumHeight: Int? { Int(rawValue) }

        var title: String {
            switch self {
            case .best: String(localized: "Best Available", comment: "Web video quality: the tallest picture the video has")
            case .p2160: "4K"
            default: "\(rawValue)p"
            }
        }
    }

    /// What happens at a stretch SponsorBlock marks.
    enum SponsorMode: String, CaseIterable {
        case automatic, offer, off

        var title: String {
            switch self {
            case .automatic: String(localized: "Skip Automatically", comment: "SponsorBlock setting: marked stretches are skipped without asking")
            case .offer: String(localized: "Show a Skip Button", comment: "SponsorBlock setting: a button offers to skip a marked stretch")
            case .off: String(localized: "Off")
            }
        }
    }

    private static var defaults: UserDefaults { .standard }

    static var quality: Quality {
        get { defaults.string(forKey: "web.quality").flatMap(Quality.init) ?? .best }
        set { defaults.set(newValue.rawValue, forKey: "web.quality") }
    }

    static var codec: WebPlaybackPreferences.Codec {
        get { defaults.string(forKey: "web.codec").flatMap(WebPlaybackPreferences.Codec.init) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "web.codec") }
    }

    static var sponsorMode: SponsorMode {
        get { defaults.string(forKey: "web.sponsorMode").flatMap(SponsorMode.init) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "web.sponsorMode") }
    }

    /// The kinds of stretch SponsorBlock is asked for: paid promotion and self-promotion, reminders to subscribe, and
    /// intros, outros and previews.
    static let sponsorCategories: [SponsorBlock.Category] = [.sponsor, .selfPromotion, .interaction, .intro, .outro, .preview]

    /// The browser whose cookies sign the viewer in to the sites yt-dlp reads; nil while signed out.
    static var cookiesBrowser: String? {
        get { defaults.string(forKey: "web.cookiesBrowser").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: "web.cookiesBrowser") }
    }

    static var hidesShorts: Bool {
        get { defaults.object(forKey: "web.hidesShorts") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "web.hidesShorts") }
    }

    /// Whether a watched video is also noted in the signed-in account's own history on its site.
    static var marksWatched: Bool {
        get { defaults.bool(forKey: "web.marksWatched") }
        set { defaults.set(newValue, forKey: "web.marksWatched") }
    }

    /// Whether the YouTube destination shows in the sidebar and the tab bar.
    static var showsDestination: Bool {
        get { defaults.object(forKey: "web.showsDestination") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "web.showsDestination") }
    }

    static func codecTitle(_ codec: WebPlaybackPreferences.Codec) -> String {
        switch codec {
        case .automatic: String(localized: "Automatic", comment: "Web video codec setting: Crucible picks")
        case .av1: "AV1"
        case .vp9: "VP9"
        case .h264: "H.264"
        }
    }
}
