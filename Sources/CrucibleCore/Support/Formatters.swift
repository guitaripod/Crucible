import Foundation

package enum Formatters {
    /// The locale of the language the interface runs in, so a decimal reads "19,8" beside German words and "19.8" beside English ones.
    package static var interfaceLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    package static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return String(localized: "\(hours)h \(minutes)m")
        } else if minutes > 0 {
            return String(localized: "\(minutes)m")
        }
        return String(localized: "< 1m")
    }

    package static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    package static func fileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            let text = String(format: "%.1f", locale: interfaceLocale, gb)
            return String(localized: "\(text) GB")
        }
        let mb = Double(bytes) / 1_048_576
        let text = String(format: "%.0f", mb)
        return String(localized: "\(text) MB")
    }

    /// A count shortened the way the interface language writes it, such as 12K or 1.2M.
    package static func compactCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).locale(interfaceLocale).precision(.significantDigits(1...3)))
    }

    package static func resolution(_ width: Int?, _ height: Int?) -> String? {
        guard let height else { return nil }
        if height >= 2160 { return "4K" }
        if height >= 1080 { return "1080p" }
        if height >= 720 { return "720p" }
        if height >= 480 { return "480p" }
        return String(localized: "\(height)p")
    }

    package static func episodeCode(_ season: Int?, _ episode: Int?) -> String? {
        guard let season, let episode else { return nil }
        let seasonText = String(format: "%02d", season)
        let episodeText = String(format: "%02d", episode)
        return String(localized: "S\(seasonText)E\(episodeText)")
    }

    package static func rating(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.1f", locale: interfaceLocale, value)
    }

    static func channelDescription(_ channels: Int?) -> String {
        switch channels {
        case 8: return "7.1"
        case 6: return "5.1"
        case 2: return String(localized: "Stereo")
        case 1: return String(localized: "Mono")
        case let n?: return String(localized: "\(n)ch")
        case nil: return String(localized: "Unknown")
        }
    }

    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relativeDate(_ isoString: String?) -> String? {
        guard let isoString else { return nil }
        let date = isoFormatterFractional.date(from: isoString) ?? isoFormatter.date(from: isoString)
        guard let date else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    package static func unixRelativeDate(_ timestamp: Int?) -> String? {
        guard let timestamp else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func unixDate(_ timestamp: Int?) -> String? {
        guard let timestamp else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return dateTimeFormatter.string(from: date)
    }

    package static func plexDate(_ dateString: String?) -> String? {
        guard let dateString else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateString) else { return nil }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}
