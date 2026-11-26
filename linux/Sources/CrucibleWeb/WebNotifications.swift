import Foundation

/// What the viewer has read, muted and checked last in the subscriptions inbox, kept with the library on this machine.
package struct WebNotificationState: Codable, Sendable, Equatable {
    /// When each notification was read, kept so the oldest can be forgotten once there are very many.
    package var read: [String: Date]
    /// Channels whose uploads stay out of the inbox and its count.
    package var mutedChannels: [String]
    /// How many read notifications are remembered; the oldest go first, and a video read long ago only comes back if the
    /// feed still carries it.
    package static let readLimit = 4000

    package init(read: [String: Date] = [:], mutedChannels: [String] = []) {
        self.read = read
        self.mutedChannels = mutedChannels
    }

    package var muted: Set<String> { Set(mutedChannels) }

    package func isRead(_ id: String) -> Bool { read[id] != nil }

    package func isMuted(channelID: String?) -> Bool {
        guard let channelID else { return false }
        return mutedChannels.contains(channelID)
    }

    package mutating func markRead(_ ids: some Sequence<String>, at date: Date = Date()) {
        for id in ids { read[id] = date }
        trimRead()
    }

    package mutating func markUnread(_ ids: some Sequence<String>) {
        for id in ids { read.removeValue(forKey: id) }
    }

    /// Mutes or unmutes a channel, keeping the list sorted so the file changes only when the set does.
    package mutating func setMuted(_ isMuted: Bool, channelID: String) {
        var channels = Set(mutedChannels)
        if isMuted { channels.insert(channelID) } else { channels.remove(channelID) }
        mutedChannels = channels.sorted()
    }

    /// Forgets the oldest read notifications past the limit.
    private mutating func trimRead() {
        guard read.count > Self.readLimit else { return }
        let newest = read.sorted { $0.value > $1.value }.prefix(Self.readLimit)
        read = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}

/// A video as the inbox shows it: its entry with what the viewer has done about it.
package struct WebInboxItem: Identifiable, Hashable, Sendable {
    package let entry: WebEntry
    package let isUnread: Bool
    package let isWatched: Bool

    package var id: String { entry.id }

    package init(entry: WebEntry, isUnread: Bool, isWatched: Bool) {
        self.entry = entry
        self.isUnread = isUnread
        self.isWatched = isWatched
    }
}

/// Where a day sits relative to today, for the inbox's headings.
package enum WebInboxDay: Hashable, Sendable {
    case today
    case yesterday
    case weekday(Int)
    case earlier
}

/// The subscriptions inbox: every new video of the channels the viewer follows, newest first, with what has been read and
/// watched, for however many channels they follow.
package enum WebInbox {
    /// Videos older than this leave the inbox, whether or not they were read.
    package static let retention: TimeInterval = 60 * 24 * 60 * 60

    package static func items(entries: [WebEntry], state: WebNotificationState, watched: Set<String>,
                              now: Date = Date()) -> [WebInboxItem] {
        let oldest = now.addingTimeInterval(-retention)
        var seen = Set<String>()
        var items: [WebInboxItem] = []
        for entry in entries {
            guard entry.kind == .video, let published = entry.published, published >= oldest else { continue }
            guard !state.isMuted(channelID: entry.channelID) else { continue }
            guard seen.insert(entry.id).inserted else { continue }
            items.append(WebInboxItem(entry: entry, isUnread: !state.isRead(entry.id), isWatched: watched.contains(entry.id)))
        }
        return items.sorted {
            let left = $0.entry.published ?? .distantPast
            let right = $1.entry.published ?? .distantPast
            return left == right ? $0.id > $1.id : left > right
        }
    }

    package static func unreadCount(entries: [WebEntry], state: WebNotificationState, watched: Set<String>,
                                    now: Date = Date()) -> Int {
        items(entries: entries, state: state, watched: watched, now: now).lazy.filter(\.isUnread).count
    }

    /// Which heading a day belongs under: today, yesterday, a weekday of the last week, or earlier.
    package static func day(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> WebInboxDay {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return .earlier }
        if calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        guard let week = calendar.date(byAdding: .day, value: -7, to: now), date >= week else { return .earlier }
        return .weekday(calendar.component(.weekday, from: date))
    }
}
