import Foundation
import Network
import os

enum DemoServerError: Error, Equatable {
    case notReady
    case cancelled
    case timedOut
}

/// Resumes a continuation at most once, whichever of several callbacks gets there first.
final class DemoResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// An HTTP/1.1 server on the loopback interface, built on Network.framework: keep-alive connections, one request at a time on each,
/// any number of connections at once. It answers on 127.0.0.1 only, so nothing outside the device can reach the demo library.
final class DemoHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (DemoRequest) async -> DemoResponse

    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "demo")
    private static let startTimeout: TimeInterval = 5
    private static let recoveryAttempts = 5

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.guitaripod.crucible.demo.http", qos: .userInitiated, attributes: .concurrent)

    private struct State {
        var listener: NWListener?
        var connections: [ObjectIdentifier: DemoConnection] = [:]
        var boundPort: UInt16 = 0
        var stopped = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var port: UInt16 {
        state.withLock { $0.boundPort }
    }

    /// Starts listening on an ephemeral loopback port and returns it once the listener is ready.
    func start() async throws -> UInt16 {
        let port = try await bind(requestedPort: .any)
        state.withLock {
            $0.boundPort = port
            $0.stopped = false
        }
        return port
    }

    /// Stops accepting, drops every connection and returns once the port no longer answers.
    func stop() async {
        let (current, open) = state.withLock { state -> (NWListener?, [DemoConnection]) in
            state.stopped = true
            let current = state.listener
            state.listener = nil
            let open = Array(state.connections.values)
            state.connections.removeAll()
            return (current, open)
        }
        for connection in open { connection.cancel() }
        guard let current else { return }
        try? await withTimeout(seconds: 2) { [queue] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = DemoResumeOnce(continuation)
                current.stateUpdateHandler = { state in
                    if case .cancelled = state { once.resume(.success(())) }
                }
                current.cancel()
                queue.asyncAfter(deadline: .now() + 2) { once.resume(.success(())) }
            }
        }
    }

    private func bind(requestedPort: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requestedPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = DemoResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    once.resume(.success(listener?.port?.rawValue ?? 0))
                case .failed(let error):
                    once.resume(.failure(error))
                    self?.listenerFailed(listener)
                case .cancelled:
                    once.resume(.failure(DemoServerError.cancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.startTimeout) { once.resume(.failure(DemoServerError.timedOut)) }
        }
        state.withLock { $0.listener = listener }
        return port
    }

    /// A listener that fails while the app runs (the system can reclaim sockets while the app is suspended) is replaced on the same
    /// port, so the address the app saved keeps working.
    private func listenerFailed(_ failed: NWListener?) {
        let (isCurrent, port) = state.withLock { ($0.listener != nil && failed === $0.listener && !$0.stopped, $0.boundPort) }
        guard isCurrent, let requested = NWEndpoint.Port(rawValue: port) else { return }
        Self.log.error("Demo listener failed; rebinding port \(port)")
        failed?.cancel()
        Task { [weak self] in
            guard let self else { return }
            for attempt in 1...Self.recoveryAttempts {
                if (try? await self.bind(requestedPort: requested)) != nil {
                    Self.log.notice("Demo listener rebound on port \(port)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200 * attempt))
            }
            Self.log.error("Demo listener could not rebind port \(port)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let demoConnection = DemoConnection(connection: connection, parent: queue, handler: handler) { [weak self] closed in
            self?.forget(closed)
        }
        let accepted = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.connections[ObjectIdentifier(demoConnection)] = demoConnection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        demoConnection.start()
    }

    private func forget(_ connection: DemoConnection) {
        state.withLock { $0.connections[ObjectIdentifier(connection)] = nil }
    }

    private func withTimeout(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw DemoServerError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

/// One accepted connection: reads a request, hands it to the handler, writes the response, and reads the next while the client keeps
/// the connection alive. All of its state lives on its own serial queue.
final class DemoConnection: @unchecked Sendable {
    private static let readSize = 256 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: DemoHTTPServer.Handler
    private let onClose: @Sendable (DemoConnection) -> Void
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, parent: DispatchQueue, handler: @escaping DemoHTTPServer.Handler, onClose: @escaping @Sendable (DemoConnection) -> Void) {
        self.connection = connection
        self.queue = DispatchQueue(label: "com.guitaripod.crucible.demo.connection", qos: .userInitiated, target: parent)
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let connection = self else { return }
                connection.queue.async { connection.finish() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.async { self.receive() }
    }

    func cancel() {
        queue.async { self.close() }
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { buffer.append(data) }
            if error != nil {
                close()
                return
            }
            process(peerFinished: isComplete)
        }
    }

    private func process(peerFinished: Bool) {
        guard !closed else { return }
        switch DemoRequestParser.parse(buffer) {
        case .incomplete:
            if peerFinished { close() } else { receive() }
        case .malformed:
            let response = DemoResponse(status: 400)
            connection.send(content: response.head(length: 0, keepAlive: false), completion: .contentProcessed { [self] _ in
                queue.async { self.close() }
            })
        case .request(let request, let keepAlive, let consumed):
            buffer = Data(buffer.dropFirst(consumed))
            dispatch(request, keepAlive: keepAlive && !peerFinished)
        }
    }

    private func dispatch(_ request: DemoRequest, keepAlive: Bool) {
        let handler = handler
        Task { [self] in
            let response = await handler(request)
            queue.async { self.write(response, for: request, keepAlive: keepAlive) }
        }
    }

    private func write(_ response: DemoResponse, for request: DemoRequest, keepAlive: Bool) {
        guard !closed else { return }
        var payload = response.head(length: response.body.count, keepAlive: keepAlive)
        if !request.isHead { payload.append(response.body) }
        connection.send(content: payload, completion: .contentProcessed { [self] error in
            queue.async {
                if error != nil || !keepAlive {
                    self.close()
                } else if self.buffer.isEmpty {
                    self.receive()
                } else {
                    self.process(peerFinished: false)
                }
            }
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose(self)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose(self)
    }
}
