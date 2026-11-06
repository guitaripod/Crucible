import Foundation
import os

/// The demo server's notification stream (`/:/eventsource/notifications`), so the demo shows the app answering a server live:
/// playback that starts and stops, scans that run and end. Every open stream gets every event, in the form a Plex Media
/// Server sends.
final class DemoEvents: Sendable {
    private let listeners = OSAllocatedUnfairLock<[UUID: AsyncStream<Data>.Continuation]>(initialState: [:])

    /// A stream of server-sent event chunks that starts with a comment, so the app sees the connection open at once.
    func subscribe() -> AsyncStream<Data> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.yield(Data(": connected\n\n".utf8))
        continuation.onTermination = { [weak self] _ in
            self?.listeners.withLock { _ = $0.removeValue(forKey: id) }
        }
        listeners.withLock { $0[id] = continuation }
        return stream
    }

    var listenerCount: Int { listeners.withLock { $0.count } }

    func playback(ratingKey: String, state: String, timeMs: Int, clientIdentifier: String?) {
        publish("playing", ["PlaySessionStateNotification": [[
            "sessionKey": "1", "clientIdentifier": clientIdentifier ?? "", "ratingKey": ratingKey,
            "key": "/library/metadata/\(ratingKey)", "viewOffset": timeMs, "state": state,
        ]]])
    }

    func scan(sectionID: String, title: String, event: String, progress: Int) {
        publish("activity", ["ActivityNotification": [[
            "event": event, "uuid": "demo-scan-\(sectionID)",
            "Activity": [
                "uuid": "demo-scan-\(sectionID)", "type": "library.update.section", "cancellable": true,
                "title": "Scanning \(title)", "progress": progress, "Context": ["librarySectionID": sectionID],
            ] as [String: Any],
        ]]])
    }

    /// A title left a library, the way a server's timeline says so once a deletion has settled.
    func deleted(ratingKey: String, sectionID: String, type: Int) {
        publish("timeline", ["TimelineEntry": [[
            "identifier": "com.plexapp.plugins.library", "sectionID": sectionID, "itemID": ratingKey, "type": type, "state": 9,
        ] as [String: Any]]])
    }

    private func publish(_ type: String, _ payload: [String: Any]) {
        var container = payload
        container["type"] = type
        container["size"] = 1
        guard let body = try? JSONSerialization.data(withJSONObject: ["NotificationContainer": container]) else { return }
        let chunk = Data("event: \(type)\ndata: ".utf8) + body + Data("\n\n".utf8)
        for continuation in listeners.withLock({ Array($0.values) }) {
            continuation.yield(chunk)
        }
    }
}
