import Foundation

/// A channel the viewer follows.
package struct WebChannel: Sendable, Codable, Hashable, Identifiable {
    /// The channel's lasting name on its site ("UC…" on YouTube), which its feed is asked for by.
    package let id: String
    package var title: String
    package var url: String
    package var handle: String?
    package var avatar: String?
    package var subscribedAt: Date

    package init(id: String, title: String, url: String? = nil, handle: String? = nil, avatar: String? = nil, subscribedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url ?? "https://www.youtube.com/channel/\(id)"
        self.handle = handle
        self.avatar = avatar
        self.subscribedAt = subscribedAt
    }
}

/// Where the viewer is in a video they opened.
package struct WebWatch: Sendable, Codable, Hashable {
    package var entry: WebEntry
    package var position: Double
    package var duration: Double
    package var watchedAt: Date
    package var isFinished: Bool

    /// How much of the video is behind the viewer, from 0 to 1.
    package var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// A video saved to this machine.
package struct WebDownload: Sendable, Codable, Hashable, Identifiable {
    package var entry: WebEntry
    /// Where the file is.
    package var path: String
    package var downloadedAt: Date

    package var id: String { entry.id }

    package init(entry: WebEntry, path: String, downloadedAt: Date = Date()) {
        self.entry = entry
        self.path = path
        self.downloadedAt = downloadedAt
    }
}

/// The viewer's own web library, kept in one file on this machine and nowhere else: the channels they follow, what they
/// saved for later, and where they are in what they watched. No site hears of any of it.
package final class WebLibrary: @unchecked Sendable {
    /// Posted (on whichever thread changed it) after the library changes.
    package static let didChange = Notification.Name("org.guitaripod.Crucible.WebLibraryDidChange")

    private struct Contents: Codable {
        var subscriptions: [WebChannel] = []
        var watchLater: [WebEntry] = []
        var history: [WebWatch] = []
        var downloads: [WebDownload]?
        var notifications: WebNotificationState?
        var notes: [WebNote]?
    }

    private let file: URL
    private let lock = NSLock()
    private var contents: Contents
    private var writeScheduled = false
    private var notificationsRevision = 0
    private var watchGeneration = 0
    private var watchIndex: [String: WebWatch]?
    private let writer = DispatchQueue(label: "org.guitaripod.Crucible.web-library", qos: .utility)
    private static let historyLimit = 3000

    package init(file: URL) {
        self.file = file
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        contents = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(Contents.self, from: $0) } ?? Contents()
    }

    // MARK: Channels

    package var subscriptions: [WebChannel] {
        lock.withLock { contents.subscriptions }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    package var subscriptionCount: Int { lock.withLock { contents.subscriptions.count } }

    package var subscriptionIDs: Set<String> { lock.withLock { Set(contents.subscriptions.map(\.id)) } }

    /// One followed channel by its ID, without sorting the rest.
    package func subscription(_ id: String) -> WebChannel? {
        lock.withLock { contents.subscriptions.first { $0.id == id } }
    }

    package func isSubscribed(to channelID: String) -> Bool {
        lock.withLock { contents.subscriptions.contains { $0.id == channelID } }
    }

    package func subscribe(to channel: WebChannel) {
        change { contents in
            if let index = contents.subscriptions.firstIndex(where: { $0.id == channel.id }) {
                var kept = channel
                kept.subscribedAt = contents.subscriptions[index].subscribedAt
                contents.subscriptions[index] = kept
            } else {
                contents.subscriptions.append(channel)
            }
        }
    }

    package func unsubscribe(from channelID: String) {
        change { $0.subscriptions.removeAll { $0.id == channelID } }
    }

    /// Follows every channel of `channels` not followed yet and returns how many that was.
    @discardableResult
    package func subscribe(toAll channels: [WebChannel]) -> Int {
        var added = 0
        change { contents in
            var known = Set(contents.subscriptions.map(\.id))
            for channel in channels where known.insert(channel.id).inserted {
                contents.subscriptions.append(channel)
                added += 1
            }
        }
        return added
    }

    /// Keeps what a channel's own page said of it (its name as it is now, its picture) with the subscription.
    package func refresh(_ channelID: String, title: String?, handle: String?, avatar: String?) {
        let current = lock.withLock { contents.subscriptions.first { $0.id == channelID } }
        guard var channel = current else { return }
        if let title, !title.isEmpty { channel.title = title }
        if let handle { channel.handle = handle }
        if let avatar { channel.avatar = avatar }
        guard channel != current else { return }
        change { contents in
            if let index = contents.subscriptions.firstIndex(where: { $0.id == channelID }) { contents.subscriptions[index] = channel }
        }
    }

    /// Keeps every channel's name a feed gave, in one library change rather than one per channel.
    package func refreshTitles(_ names: [String: String]) {
        guard !names.isEmpty else { return }
        let current = lock.withLock { contents.subscriptions }
        let changed = current.contains { channel in
            guard let name = names[channel.id], !name.isEmpty else { return false }
            return name != channel.title
        }
        guard changed else { return }
        change { contents in
            for index in contents.subscriptions.indices {
                guard let name = names[contents.subscriptions[index].id], !name.isEmpty else { continue }
                contents.subscriptions[index].title = name
            }
        }
    }

    // MARK: Notifications

    /// What the viewer read and muted in the subscriptions inbox.
    package var notificationState: WebNotificationState {
        lock.withLock { contents.notifications ?? WebNotificationState() }
    }

    /// Counts the changes that can alter the inbox or its unread count, so a badge does not sort a thousand videos again
    /// for every ten seconds of playback.
    package var notificationRevision: Int {
        lock.withLock { notificationsRevision }
    }

    private func bumpNotificationRevision() {
        lock.withLock { notificationsRevision &+= 1 }
    }

    /// Counts the changes to whether a video is finished, which the inbox draws as a dimmed card; progress that does not
    /// finish one leaves it alone.
    package var watchRevision: Int {
        lock.withLock { watchGeneration }
    }

    package func markNotificationsRead(_ ids: [String], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        let known = notificationState
        guard ids.contains(where: { !known.isRead($0) }) else { return }
        var changed = false
        change { contents in
            var state = contents.notifications ?? WebNotificationState()
            changed = state.markRead(ids, at: date)
            if changed { contents.notifications = state }
        } then: {
            if changed { self.bumpNotificationRevision() }
        }
    }

    package func markNotificationsUnread(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let known = notificationState
        guard ids.contains(where: { known.isRead($0) }) else { return }
        var changed = false
        change { contents in
            var state = contents.notifications ?? WebNotificationState()
            changed = state.markUnread(ids)
            if changed { contents.notifications = state }
        } then: {
            if changed { self.bumpNotificationRevision() }
        }
    }

    /// Keeps a channel's uploads out of the inbox without unfollowing the channel.
    package func setNotificationMuted(_ isMuted: Bool, channelID: String) {
        guard !channelID.isEmpty else { return }
        let known = notificationState
        guard known.isMuted(channelID: channelID) != isMuted else { return }
        var changed = false
        change { contents in
            var state = contents.notifications ?? WebNotificationState()
            changed = state.setMuted(isMuted, channelID: channelID)
            if changed { contents.notifications = state }
        } then: {
            if changed { self.bumpNotificationRevision() }
        }
    }

    package func isNotificationMuted(channelID: String) -> Bool {
        notificationState.isMuted(channelID: channelID)
    }

    /// The comment, mention and live notes the signed-in account's inbox last gave, newest first.
    package var notes: [WebNote] {
        lock.withLock { contents.notes ?? [] }
    }

    /// Takes what the account's inbox said, keeping the first time each note was seen and forgetting notes older than the
    /// inbox keeps. A note YouTube marks read is read here too.
    package func replaceNotes(_ notes: [WebNote], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-WebInbox.retention)
        let existing = lock.withLock { contents.notes ?? [] }
        let seen = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.publishedAt) })
        var merged = notes.map { note -> WebNote in
            var kept = note
            if let first = seen[note.id] { kept.publishedAt = first }
            return kept
        }
        merged.sort { $0.publishedAt > $1.publishedAt }
        merged = Array(merged.filter { $0.publishedAt >= cutoff }.prefix(200))
        guard merged != existing else { return }
        change { contents in
            contents.notes = merged
            var state = contents.notifications ?? WebNotificationState()
            state.markRead(merged.filter(\.isRead).map(\.id), at: now)
            contents.notifications = state
        } then: {
            self.bumpNotificationRevision()
        }
    }

    // MARK: Watch Later

    /// What was saved for later, the newest first.
    package var watchLater: [WebEntry] { lock.withLock { contents.watchLater } }

    package func isSavedForLater(_ id: String) -> Bool {
        lock.withLock { contents.watchLater.contains { $0.id == id } }
    }

    package func saveForLater(_ entry: WebEntry) {
        change { contents in
            contents.watchLater.removeAll { $0.id == entry.id }
            contents.watchLater.insert(entry, at: 0)
        }
    }

    package func removeFromWatchLater(_ id: String) {
        change { $0.watchLater.removeAll { $0.id == id } }
    }

    /// Takes several videos out of Watch Later at once, as one change.
    package func removeFromWatchLater(ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        change { $0.watchLater.removeAll { gone.contains($0.id) } }
    }

    /// Puts Watch Later back as it was before a clear, keeping what was saved since in front.
    package func restoreToWatchLater(_ previous: [WebEntry]) {
        guard !previous.isEmpty else { return }
        let known = Set(previous.map(\.id))
        change { $0.watchLater = $0.watchLater.filter { !known.contains($0.id) } + previous }
    }

    // MARK: Downloads

    /// The videos saved to this machine whose files are still there, the newest first.
    package var downloads: [WebDownload] {
        (lock.withLock { contents.downloads } ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    package func download(of id: String) -> WebDownload? {
        downloads.first { $0.id == id }
    }

    package func noteDownload(_ download: WebDownload) {
        change { contents in
            var kept = (contents.downloads ?? []).filter { $0.id != download.id }
            kept.insert(download, at: 0)
            contents.downloads = kept
        }
    }

    /// Forgets a download; its file is the caller's to remove.
    package func forgetDownload(_ id: String) {
        change { $0.downloads?.removeAll { $0.id == id } }
    }

    // MARK: History

    /// Everything watched, the latest first.
    package var history: [WebWatch] { lock.withLock { contents.history } }

    /// What was begun and not finished, the latest first.
    package var continueWatching: [WebWatch] {
        lock.withLock { contents.history }.filter { !$0.isFinished && $0.position >= Self.worthResuming && !$0.entry.isLive }
    }

    package func watch(of id: String) -> WebWatch? {
        lock.withLock {
            if watchIndex == nil {
                watchIndex = Dictionary(contents.history.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            return watchIndex?[id]
        }
    }

    /// Where to pick a video up: where it was left, or the start when it was finished or barely begun.
    package func resumePosition(of id: String) -> Double {
        guard let watch = watch(of: id), !watch.isFinished, watch.position >= Self.worthResuming else { return 0 }
        return watch.position
    }

    /// Notes that `entry` was watched up to `position`; a video watched to its last stretch counts as finished and
    /// leaves Watch Later.
    package func record(_ entry: WebEntry, position: Double, duration: Double, at date: Date = Date()) {
        let finished = Self.isFinished(position: position, duration: duration)
        var readChanged = false
        var watchChanged = false
        change { contents in
            let wasFinished = contents.history.first { $0.entry.id == entry.id }?.isFinished ?? false
            if wasFinished != finished { watchChanged = true }
            contents.history.removeAll { $0.entry.id == entry.id }
            contents.history.insert(WebWatch(entry: entry, position: max(position, 0), duration: max(duration, 0), watchedAt: date, isFinished: finished), at: 0)
            if contents.history.count > Self.historyLimit { contents.history.removeLast(contents.history.count - Self.historyLimit) }
            if finished { contents.watchLater.removeAll { $0.id == entry.id } }
            var notifications = contents.notifications ?? WebNotificationState()
            if notifications.markRead([entry.id], at: date) {
                contents.notifications = notifications
                readChanged = true
            }
        } then: {
            if readChanged { self.bumpNotificationRevision() }
            self.lock.withLock {
                if watchChanged { self.watchGeneration &+= 1 }
                self.watchIndex = nil
            }
        }
    }

    package func removeFromHistory(_ id: String) {
        var watchedChanged = false
        change { contents in
            if contents.history.first(where: { $0.entry.id == id })?.isFinished == true { watchedChanged = true }
            contents.history.removeAll { $0.entry.id == id }
        } then: {
            self.lock.withLock {
                if watchedChanged { self.watchGeneration &+= 1 }
                self.watchIndex = nil
            }
        }
    }

    package func clearHistory() {
        var watchedChanged = false
        change { contents in
            watchedChanged = contents.history.contains(where: \.isFinished)
            contents.history = []
        } then: {
            self.lock.withLock {
                if watchedChanged { self.watchGeneration &+= 1 }
                self.watchIndex = nil
            }
        }
    }

    /// A position under ten seconds is a video opened by mistake, not one to carry on with.
    static let worthResuming: Double = 10

    /// Finished once less than a twentieth of the video is left, or its last twenty seconds are reached.
    package static func isFinished(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return position >= duration * 0.95 || duration - position <= min(20, duration * 0.5)
    }

    // MARK: Keeping

    /// Applies `body`, then `settle` (the revision counters the change moved), and only then tells observers, so a
    /// screen that compares those counters on the notice sees the new ones.
    private func change(_ body: (inout Contents) -> Void, then settle: () -> Void = {}) {
        let schedule = lock.withLock {
            body(&contents)
            defer { writeScheduled = true }
            return !writeScheduled
        }
        if schedule { writer.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.write() } }
        settle()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Writes the library now, as before the app quits.
    package func flush() {
        writer.sync { write() }
    }

    private func write() {
        let snapshot = lock.withLock {
            writeScheduled = false
            return contents
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// Reads the channels out of a subscriptions file from somewhere else: Google Takeout's `subscriptions.csv`, an OPML list
/// of feeds, NewPipe's or Invidious's JSON export, FreeTube's profiles, or plain lines of channel addresses.
package enum WebSubscriptionImport {
    package static func channels(in data: Data, now: Date = Date()) -> [WebChannel] {
        let text = String(decoding: data, as: UTF8.self)
        var found: [WebChannel] = []
        var seen: Set<String> = []
        func add(_ id: String?, _ title: String?) {
            guard let id, seen.insert(id).inserted else { return }
            let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            found.append(WebChannel(id: id, title: name.isEmpty ? id : name, subscribedAt: now))
        }
        if text.contains("<opml") || text.contains("<outline") {
            for outline in text.components(separatedBy: "<outline").dropFirst() {
                let tag = outline.prefix { $0 != ">" }
                add(channelID(in: String(tag)), attribute("title", in: tag) ?? attribute("text", in: tag))
            }
            return found
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let objects = lines.count > 1 && lines.allSatisfy { $0.hasPrefix("{") } ? lines : [text]
        var readJSON = false
        for object in objects {
            guard let json = try? JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any], let listed = json["subscriptions"] as? [Any]
            else { continue }
            readJSON = true
            for item in listed {
                if let id = item as? String {
                    add(channelID(in: id), nil)
                } else if let fields = item as? [String: Any] {
                    let address = (fields["url"] as? String) ?? (fields["id"] as? String) ?? ""
                    add(channelID(in: address), fields["name"] as? String)
                }
            }
        }
        if readJSON { return found }
        for line in lines {
            let fields = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let title = fields.count == 3 ? fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) : nil
            add(channelID(in: line), title)
        }
        return found
    }

    /// The followed channels as an OPML list of their feeds, which feed readers and other YouTube apps take in.
    package static func opml(_ channels: [WebChannel]) -> Data {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<opml version=\"1.1\">", "<body>", "<outline text=\"YouTube Subscriptions\" title=\"YouTube Subscriptions\">"]
        for channel in channels {
            let name = escaped(channel.title)
            let feed = escaped(WebFeed.address(channelID: channel.id)?.absoluteString ?? "")
            lines.append("<outline text=\"\(name)\" title=\"\(name)\" type=\"rss\" xmlUrl=\"\(feed)\" htmlUrl=\"\(escaped(channel.url))\" />")
        }
        lines += ["</outline>", "</body>", "</opml>", ""]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The first YouTube channel ID in `text`: "UC" and the twenty-two characters after it.
    package static func channelID(in text: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        var search = Substring(text)
        while let start = search.range(of: "UC") {
            let candidate = search[start.lowerBound...].prefix(24)
            let after = search[start.lowerBound...].dropFirst(24).first
            let before = start.lowerBound > text.startIndex ? text[text.index(before: start.lowerBound)] : nil
            if candidate.count == 24, candidate.allSatisfy(allowed.contains), after.map({ !allowed.contains($0) }) ?? true,
               before.map({ !allowed.contains($0) }) ?? true {
                return String(candidate)
            }
            search = search[start.upperBound...]
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let start = tag.range(of: " \(name)=\""), let stop = tag.range(of: "\"", range: start.upperBound..<tag.endIndex) else { return nil }
        return WebFeed.unescaped(String(tag[start.upperBound..<stop.lowerBound]))
    }
}
