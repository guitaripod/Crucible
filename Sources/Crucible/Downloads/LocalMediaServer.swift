import Foundation
import Network
import os

/// A tiny loopback HTTP server that serves downloaded HLS assets to AVPlayer. AVPlayer does not
/// reliably play a local `file://` HLS playlist (Apple's only sanctioned offline-HLS path is
/// `.movpkg`, which Plex's on-demand transcode breaks), but it plays HTTP HLS perfectly — so offline
/// playback points at `http://127.0.0.1:<port>/<ratingKey>/index.m3u8`, served from the on-disk
/// segment folder. Bound to the loopback interface, so nothing off-device can reach it.
final class LocalMediaServer: @unchecked Sendable {
    static let shared = LocalMediaServer()
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")

    private let queue = DispatchQueue(label: "com.guitaripod.crucible.mediaserver")
    private var listener: NWListener?
    private let portValue = OSAllocatedUnfairLock<UInt16>(initialState: 0)

    var port: UInt16 { portValue.withLock { $0 } }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            Self.log.error("Local media server failed to create listener")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port?.rawValue {
                self?.portValue.withLock { $0 = port }
                Self.log.notice("Local media server ready on port \(port)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func playlistURL(ratingKey: String) -> URL? {
        let port = port
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(ratingKey)/index.m3u8")
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                self.respond(connection, header: String(decoding: headerData, as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2, requestLine[0] == "GET",
              let path = String(requestLine[1]).removingPercentEncoding else {
            send(connection, status: 400)
            return
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 2, !components.contains(".."), !components.contains("") else {
            send(connection, status: 404)
            return
        }
        let fileURL = DownloadPaths.directory
            .appendingPathComponent(components[0])
            .appendingPathComponent(components[1])
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            send(connection, status: 404)
            return
        }

        let contentType: String
        if components[1].hasSuffix(".m3u8") { contentType = "application/vnd.apple.mpegurl" }
        else if components[1].hasSuffix(".ts") { contentType = "video/mp2t" }
        else if components[1].hasSuffix(".mp4") || components[1].hasSuffix(".m4s") { contentType = "video/mp4" }
        else { contentType = "application/octet-stream" }

        let rangeLine = lines.first { $0.lowercased().hasPrefix("range:") }
        if let rangeLine, let range = parseRange(rangeLine, total: data.count) {
            var headers = "HTTP/1.1 206 Partial Content\r\n"
            headers += "Content-Type: \(contentType)\r\n"
            headers += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)\r\n"
            headers += "Content-Length: \(range.count)\r\n"
            headers += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            send(connection, Data(headers.utf8) + data.subdata(in: range))
        } else {
            var headers = "HTTP/1.1 200 OK\r\n"
            headers += "Content-Type: \(contentType)\r\n"
            headers += "Content-Length: \(data.count)\r\n"
            headers += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            send(connection, Data(headers.utf8) + data)
        }
    }

    private func parseRange(_ line: String, total: Int) -> Range<Int>? {
        guard let eq = line.firstIndex(of: "="), total > 0 else { return nil }
        let spec = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = bounds.first else { return nil }
        let start = Int(first) ?? 0
        let end = (bounds.count > 1 ? Int(bounds[1]) : nil) ?? (total - 1)
        let lower = max(0, start)
        let upper = min(total - 1, end)
        guard lower <= upper else { return nil }
        return lower..<(upper + 1)
    }

    private func send(_ connection: NWConnection, status: Int) {
        let message = "HTTP/1.1 \(status) \r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        send(connection, Data(message.utf8))
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
