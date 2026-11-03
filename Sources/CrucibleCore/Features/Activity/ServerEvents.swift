import Foundation
import MidgarCore

/// Something the server announced on its live notification stream, reduced to what the app reacts to.
package enum ServerEvent: Sendable, Equatable {
    /// A player started, paused, resumed or stopped `ratingKey`; `clientIdentifier` names the device it plays on.
    case playback(ratingKey: String?, state: String, clientIdentifier: String?)
    /// A background job of the server (a scan, a refresh, an analysis) started, moved on or ended.
    case activity(type: String?, event: String?, progress: Int?)
    /// A title of a library was added, finished processing or was deleted, or a scan of the library ended.
    case library(sectionID: String?, ratingKey: String?)

    /// Playback on another device: this one already knows what it plays itself.
    package var isPlaybackElsewhere: Bool {
        guard case .playback(_, _, let client) = self else { return false }
        return client != PlexHeaders.clientIdentifier
    }

    /// Playback elsewhere that stopped, which moves Continue Watching.
    package var isStopElsewhere: Bool {
        guard isPlaybackElsewhere, case .playback(_, let state, _) = self else { return false }
        return state == "stopped"
    }

    /// What changes Home: something stopped playing on another device (Continue Watching, On Deck) or a library gained or lost a title.
    package var changesHome: Bool {
        isStopElsewhere || isLibraryChange
    }

    package var isPlayback: Bool {
        if case .playback = self { return true }
        return false
    }

    package var isActivity: Bool {
        if case .activity = self { return true }
        return false
    }

    package var isLibraryChange: Bool {
        if case .library = self { return true }
        return false
    }
}

/// Splits a server-sent event stream into its events: `event:` names one, `data:` lines carry its body, a blank line ends it
/// and a line starting with a colon is a comment the server sends to keep the connection open.
package struct ServerEventParser: Sendable {
    private var type: String?
    private var data: [String] = []

    package init() {}

    /// Takes one line of the stream without its line ending, and returns the event it completes, if any.
    package mutating func feed(_ line: String) -> (type: String?, data: String)? {
        if line.isEmpty { return flush() }
        guard !line.hasPrefix(":") else { return nil }
        let (field, value) = Self.field(of: line)
        switch field {
        case "event": type = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }

    private mutating func flush() -> (type: String?, data: String)? {
        defer {
            type = nil
            data = []
        }
        guard !data.isEmpty else { return nil }
        return (type, data.joined(separator: "\n"))
    }

    private static func field(of line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}

/// Reads the body of one event. The server wraps it in a `NotificationContainer` on its WebSocket and may leave the wrapper out
/// on the event stream, gives each kind as one object or a list, and writes numbers as numbers or strings; all of it is read.
package enum ServerEventDecoder {
    /// Plex's library item types that are video titles: movie, show, season, episode.
    private static let videoTypes: Set<Int> = [1, 2, 3, 4]
    /// A timeline entry's state once the item is in the library and processed, and once it is gone.
    private static let settledStates: Set<Int> = [5, 9]

    package static func events(type: String?, data: String) -> [ServerEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return [] }
        let body = object["NotificationContainer"] as? [String: Any] ?? object
        switch type ?? body["type"] as? String {
        case "playing": return entries(body["PlaySessionStateNotification"]).compactMap(playback)
        case "activity": return entries(body["ActivityNotification"]).flatMap(activity)
        case "timeline": return entries(body["TimelineEntry"]).compactMap(timeline)
        default: return []
        }
    }

    private static func playback(_ entry: [String: Any]) -> ServerEvent? {
        guard let state = text(entry["state"]) else { return nil }
        return .playback(ratingKey: text(entry["ratingKey"]), state: state, clientIdentifier: text(entry["clientIdentifier"]))
    }

    /// A job that moved on, and when a scan or refresh of a library ends, that library too.
    private static func activity(_ entry: [String: Any]) -> [ServerEvent] {
        let job = entry["Activity"] as? [String: Any] ?? [:]
        let type = text(job["type"])
        let event = text(entry["event"])
        var events: [ServerEvent] = [.activity(type: type, event: event, progress: text(job["progress"]).flatMap { Int(Double($0) ?? -1) }.flatMap { $0 >= 0 ? $0 : nil })]
        if event == "ended", let type, type.hasPrefix("library.update") || type.hasPrefix("library.refresh") {
            let context = job["Context"] as? [String: Any]
            events.append(.library(sectionID: text(context?["librarySectionID"]), ratingKey: nil))
        }
        return events
    }

    private static func timeline(_ entry: [String: Any]) -> ServerEvent? {
        if let identifier = text(entry["identifier"]), identifier != "com.plexapp.plugins.library" { return nil }
        guard let type = text(entry["type"]).flatMap(Int.init), videoTypes.contains(type),
              let state = text(entry["state"]).flatMap(Int.init), settledStates.contains(state) else { return nil }
        return .library(sectionID: text(entry["sectionID"]), ratingKey: text(entry["itemID"]))
    }

    private static func entries(_ value: Any?) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let one = value as? [String: Any] { return [one] }
        return []
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}

/// One connection to the server's event stream (`/:/eventsource/notifications`), read until it ends.
package enum ServerEventStream {
    package static let filters = "playing,activity,timeline"
    /// How long the connection may stay silent before it is dropped and opened again.
    package static let idleTimeout: TimeInterval = 300

    enum Outcome: Equatable {
        /// The server answered with something other than a stream (an old server, the demo, a token it no longer takes).
        case refused
        case dropped(lasted: Duration)
    }

    static func listen(api: APIClient, deliver: @escaping @Sendable (ServerEvent) async -> Void) async -> Outcome {
        let started = ContinuousClock.now
        do {
            let request = try PlexEndpoint.eventSource.urlRequest(baseURL: await api.baseURL, token: api.token)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                MidgarLog.notice("Server events refused with HTTP \(status)", category: .networking)
                return isRefusal(status) ? .refused : .dropped(lasted: started.duration(to: .now))
            }
            MidgarLog.notice("Server events connected", category: .networking)
            var parser = ServerEventParser()
            var line: [UInt8] = []
            for try await byte in bytes {
                guard byte == 0x0A else {
                    line.append(byte)
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                if let event = parser.feed(String(decoding: line, as: UTF8.self)) {
                    for decoded in ServerEventDecoder.events(type: event.type, data: event.data) {
                        await deliver(decoded)
                    }
                }
                line.removeAll(keepingCapacity: true)
            }
        } catch {
            if !Task.isCancelled {
                MidgarLog.notice("Server events dropped: \(error.localizedDescription)", category: .networking)
            }
        }
        return .dropped(lasted: started.duration(to: .now))
    }

    /// A client error the server will give again: not found, not allowed, not supported. A timeout or rate limit is worth retrying.
    static func isRefusal(_ status: Int) -> Bool {
        (400..<500).contains(status) && status != 408 && status != 429
    }

    /// The wait before opening the stream again: a second after a connection that had been up a while, then longer for each one
    /// that failed straight away, up to a minute.
    static func backoff(after failures: Int) -> Duration {
        guard failures > 0 else { return .seconds(1) }
        return .seconds(min(60, 2 << min(failures, 5)))
    }
}

/// One live connection to the server's event stream, shared by every screen that listens. The first listener opens it, the last
/// one to leave closes it, and it reconnects after a drop. A server that refuses the stream is not asked again until the app
/// talks to another one, and the screens fall back on the refreshes they always had.
@MainActor
package final class ServerEventHub {
    package static let shared = ServerEventHub()

    private struct Listener {
        let interval: Duration
        let matches: @Sendable (ServerEvent) -> Bool
        let action: @MainActor () -> Void
        var scheduled: Task<Void, Never>?
    }

    private var listeners: [UUID: Listener] = [:]
    private var connection: Task<Void, Never>?
    private var connectedAPI: APIClient?
    private var refusedAPI: ObjectIdentifier?

    package init() {}

    /// Runs `action` once events that `matches` have arrived, at most once every `interval`: the first such event starts the
    /// wait and everything that arrives during it is answered by the same run. Lasts until the returned listening is cancelled.
    package func listen(
        api: APIClient,
        every interval: Duration = .seconds(2),
        matching matches: @escaping @Sendable (ServerEvent) -> Bool,
        action: @escaping @MainActor () -> Void
    ) -> ServerEventListening {
        let id = UUID()
        listeners[id] = Listener(interval: interval, matches: matches, action: action)
        connect(api)
        return ServerEventListening(id: id, hub: self)
    }

    /// Whether the stream is open, or being opened again after a drop.
    package var isConnected: Bool { connection != nil }

    func remove(_ id: UUID) {
        listeners.removeValue(forKey: id)?.scheduled?.cancel()
        guard listeners.isEmpty else { return }
        connection?.cancel()
        connection = nil
        connectedAPI = nil
    }

    func receive(_ event: ServerEvent) {
        forgetCachedTitle(after: event)
        for (id, listener) in listeners where listener.scheduled == nil && listener.matches(event) {
            var listener = listener
            let interval = listener.interval
            listener.scheduled = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, var current = listeners[id] else { return }
                current.scheduled = nil
                listeners[id] = current
                current.action()
            }
            listeners[id] = listener
        }
    }

    /// A title that stopped playing somewhere or changed in its library is read afresh the next time a screen asks for it.
    private func forgetCachedTitle(after event: ServerEvent) {
        let key: String?
        switch event {
        case .playback(let ratingKey, let state, _): key = state == "stopped" ? ratingKey : nil
        case .library(_, let ratingKey): key = ratingKey
        case .activity: key = nil
        }
        guard let key, let api = connectedAPI else { return }
        Task { await api.invalidate(ratingKey: key) }
    }

    private func connect(_ api: APIClient) {
        if connectedAPI === api, connection != nil { return }
        connection?.cancel()
        connection = nil
        connectedAPI = api
        guard refusedAPI != ObjectIdentifier(api) else { return }
        connection = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let outcome = await ServerEventStream.listen(api: api) { [weak self] event in
                    await self?.receive(event)
                }
                guard !Task.isCancelled else { return }
                switch outcome {
                case .refused:
                    self?.refusedAPI = ObjectIdentifier(api)
                    self?.connection = nil
                    return
                case .dropped(let lasted):
                    failures = lasted > .seconds(30) ? 0 : failures + 1
                }
                try? await Task.sleep(for: ServerEventStream.backoff(after: failures))
            }
        }
    }
}

/// A screen's hold on the event stream: cancel it when the screen goes away, or let it go.
@MainActor
package final class ServerEventListening {
    private let id: UUID
    private weak var hub: ServerEventHub?

    init(id: UUID, hub: ServerEventHub) {
        self.id = id
        self.hub = hub
    }

    package func cancel() {
        hub?.remove(id)
        hub = nil
    }

    /// Keeps listening until the calling task is cancelled, for screens whose work lives in a task tied to their visibility.
    package func hold() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        cancel()
    }
}
