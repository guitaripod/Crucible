import CrucibleCore
import Foundation
import MidgarCore
@preconcurrency import Network

/// Plays a bare MPEG transport stream (what most IPTV services send) through AVPlayer, which only takes HLS: the relay reads
/// the stream, cuts it into keyframe-aligned segments with `TransportStreamSegmenter` and serves a live playlist of the
/// latest ones under a random path from a server bound to the device's loopback address, which nothing off the device can
/// reach. It takes any loopback connection, as AVPlayer fetches through the system's media server, not this process. A
/// stream that drops is read again and the playlist marks the seam; an address that turns out to be HLS after all is handed
/// back to play directly.
package final class LiveStreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    package enum Outcome: Sendable {
        /// Play this loopback playlist.
        case relayed(URL)
        /// The address answered with an HLS playlist: play it as it is.
        case hls(URL)
    }

    package enum Failure: Error, LocalizedError {
        case noPicture
        case refused(Int)
        case stopped

        package var errorDescription: String? {
            switch self {
            case .noPicture: return String(localized: "The channel sent nothing that could be played.", comment: "Live TV error when a stream never produced a picture")
            case .refused(let status): return String(localized: "The channel’s server answered \(status).", comment: "Live TV error with the HTTP status a stream answered")
            case .stopped: return String(localized: "The channel stopped.", comment: "Live TV error when the stream ended")
            }
        }
    }

    private static let startTimeout: Duration = .seconds(25)
    private static let stallLimit: TimeInterval = 15
    private static let segmentsBeforePlaying = 2

    private let source: URL
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "com.guitaripod.crucible.live-relay")
    private let pathToken = UUID().uuidString.lowercased()
    private var listener: NWListener?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var segmenter = TransportStreamSegmenter(targetDuration: 2)
    private var window = LiveHLSWindow(capacity: 8)
    private var port: UInt16 = 0
    private var sniffed = false
    private var restartPending = false
    private var nextIsDiscontinuity = false
    private var lastData = Date()
    private var stopped = false
    private var reconnects = 0
    private var waiter: CheckedContinuation<Outcome, Error>?
    private var stallTimer: DispatchSourceTimer?

    package init(source: URL, headers: [String: String]) {
        self.source = source
        self.headers = headers
        super.init()
    }

    /// Starts reading and serving, and returns once the first segments are ready (or the address proved to be HLS).
    package func start() async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.begin(continuation) }
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Stops reading, closes the server and drops what was held.
    package func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.task?.cancel()
            self.session?.invalidateAndCancel()
            self.listener?.cancel()
            self.stallTimer?.cancel()
            self.finish(.failure(Failure.stopped))
            MidgarLog.notice("Live relay stopped after \(self.segmenter.bytesRead / 1024) KiB, \(self.reconnects) reconnects", category: .liveTV)
        }
    }

    private func begin(_ continuation: CheckedContinuation<Outcome, Error>) {
        waiter = continuation
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            finish(.failure(error))
            return
        }
        queue.asyncAfter(deadline: .now() + .seconds(Int(Self.startTimeout.components.seconds))) { [weak self] in
            guard let self, self.waiter != nil else { return }
            MidgarLog.error("Live relay had no segments after \(Self.startTimeout)", category: .liveTV)
            self.finish(.failure(Failure.noPicture))
            self.stop()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            connect()
            watchForStalls()
        case .failed(let error):
            finish(.failure(error))
        default:
            break
        }
    }

    private func connect() {
        guard !stopped else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = .infinity
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session?.invalidateAndCancel()
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        var request = URLRequest(url: source)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let task = session.dataTask(with: request)
        self.task = task
        sniffed = false
        lastData = Date()
        task.resume()
    }

    /// Reads the stream again from scratch after it dropped or stalled, carrying the segment numbering on.
    private func reconnect() {
        guard !stopped, !restartPending else { return }
        restartPending = true
        reconnects += 1
        let wait = min(Double(reconnects), 5)
        MidgarLog.notice("Live relay reconnecting (\(reconnects)) in \(wait) s", category: .liveTV)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.stopped else { return }
            self.restartPending = false
            self.segmenter = TransportStreamSegmenter(targetDuration: 2, firstSequence: self.segmenter.nextSequenceNumber)
            self.nextIsDiscontinuity = true
            self.connect()
        }
    }

    private func watchForStalls() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.restartPending, Date().timeIntervalSince(self.lastData) > Self.stallLimit else { return }
            MidgarLog.notice("Live relay stalled for \(Int(Self.stallLimit)) s", category: .liveTV)
            self.task?.cancel()
            self.reconnect()
        }
        timer.resume()
        stallTimer = timer
    }

    private func finish(_ result: Result<Outcome, Error>) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(with: result)
    }

    private var playlistURL: URL {
        URL(string: "http://127.0.0.1:\(port)/\(pathToken)/live.m3u8")!
    }

    // MARK: Reading

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            MidgarLog.error("Live stream answered \(http.statusCode)", category: .liveTV)
            completionHandler(.cancel)
            if waiter != nil { finish(.failure(Failure.refused(http.statusCode))) } else { reconnect() }
            return
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("mpegurl"), let url = http.url, waiter != nil {
            completionHandler(.cancel)
            finish(.success(.hls(url)))
            stop()
            return
        }
        completionHandler(.allow)
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        lastData = Date()
        if !sniffed {
            sniffed = true
            if data.starts(with: Data("#EXTM3U".utf8)), let url = dataTask.response?.url ?? dataTask.originalRequest?.url, waiter != nil {
                dataTask.cancel()
                finish(.success(.hls(url)))
                stop()
                return
            }
        }
        for segment in segmenter.append(data) {
            window.add(segment, discontinuity: nextIsDiscontinuity)
            nextIsDiscontinuity = false
            if waiter != nil, window.segments.count >= Self.segmentsBeforePlaying {
                MidgarLog.notice("Live relay ready on port \(port)\(segmenter.hasVideo ? "" : " (sound only)")", category: .liveTV)
                finish(.success(.relayed(playlistURL)))
            }
        }
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped, task === self.task else { return }
        if let error, (error as? URLError)?.code == .cancelled { return }
        MidgarLog.notice("Live stream ended: \(error?.localizedDescription ?? "the server closed it")", category: .liveTV)
        if waiter != nil, reconnects >= 2 {
            finish(.failure(error ?? Failure.stopped))
            return
        }
        reconnect()
    }

    // MARK: Serving

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                MidgarLog.info("Live relay connection failed: \(error)", category: .liveTV)
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Reads requests one after another on a kept-alive connection, as AVPlayer reuses its connections; the peer closing
    /// it, or an error, ends it.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let rest = buffer[end.upperBound...]
            respond(to: buffer[..<end.lowerBound], on: connection) { [weak self] in self?.receiveRequest(on: connection, buffer: Data(rest)) }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var received = buffer
            if let content { received.append(content) }
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.receiveRequest(on: connection, buffer: received)
            } else if isComplete || received.count > 16384 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: received)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection, then next: @escaping @Sendable () -> Void) {
        let line = String(decoding: head.prefix { $0 != 0x0D && $0 != 0x0A }, as: UTF8.self)
        let parts = line.split(separator: " ")
        let path = parts.count >= 2 ? String(parts[1]) : ""
        let prefix = "/\(pathToken)/"
        guard parts.first == "GET" || parts.first == "HEAD", path.hasPrefix(prefix) else {
            MidgarLog.info("Live relay refused \(line)", category: .liveTV)
            send(status: "404 Not Found", type: "text/plain", body: Data(), on: connection, then: next)
            return
        }
        let name = String(path.dropFirst(prefix.count))
        MidgarLog.debug("Live relay \(parts[0]) \(name)", category: .liveTV)
        if name == "live.m3u8" {
            send(status: "200 OK", type: "application/vnd.apple.mpegurl", body: Data(window.playlist.utf8), on: connection, then: next)
        } else if name.hasPrefix("segment-"), name.hasSuffix(".ts"), let sequence = Int(name.dropFirst(8).dropLast(3)), let segment = window.segment(sequence) {
            send(status: "200 OK", type: "video/mp2t", body: parts.first == "HEAD" ? Data() : segment.data, length: segment.data.count, on: connection, then: next)
        } else {
            send(status: "404 Not Found", type: "text/plain", body: Data(), on: connection, then: next)
        }
    }

    private func send(status: String, type: String, body: Data, length: Int? = nil, on connection: NWConnection, then next: @escaping @Sendable () -> Void) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length ?? body.count)\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
            if error != nil { connection.cancel() } else { next() }
        })
    }
}
