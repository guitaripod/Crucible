import Foundation

enum Formatters {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        }
        return "< 1m"
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func fileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    static func resolution(_ width: Int?, _ height: Int?) -> String? {
        guard let height else { return nil }
        if height >= 2160 { return "4K" }
        if height >= 1080 { return "1080p" }
        if height >= 720 { return "720p" }
        if height >= 480 { return "480p" }
        return "\(height)p"
    }

    static func episodeCode(_ season: Int?, _ episode: Int?) -> String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    static func rating(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.1f", value)
    }

    static func channelDescription(_ channels: Int?) -> String {
        switch channels {
        case 8: return "7.1"
        case 6: return "5.1"
        case 2: return "Stereo"
        case 1: return "Mono"
        case let n?: return "\(n)ch"
        case nil: return "Unknown"
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
}
