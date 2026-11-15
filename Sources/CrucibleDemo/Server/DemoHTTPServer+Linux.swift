#if !canImport(Network)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An HTTP/1.1 server on the loopback interface over POSIX sockets, for Linux, where Network.framework does not exist:
/// keep-alive connections, one request at a time on each, any number of connections at once, each on a thread of its own.
/// It answers on 127.0.0.1 only, so nothing outside the machine can reach the demo library.
final class DemoHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (DemoRequest) async -> DemoResponse

    private static let backlog: Int32 = 128

    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections: [ObjectIdentifier: DemoSocketConnection] = [:]
    private var boundPort: UInt16 = 0
    private var stopped = false
    private var accepting: DispatchGroup?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var port: UInt16 {
        lock.withLock { boundPort }
    }

    /// Starts listening on an ephemeral loopback port and returns it once the socket listens.
    func start() async throws -> UInt16 {
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard descriptor >= 0 else { throw DemoServerError.notReady }
        guard let port = Self.listen(on: descriptor) else {
            close(descriptor)
            throw DemoServerError.notReady
        }
        let group = DispatchGroup()
        group.enter()
        lock.withLock {
            listener = descriptor
            boundPort = port
            stopped = false
            accepting = group
        }
        let thread = Thread { [self] in
            acceptLoop(descriptor)
            close(descriptor)
            group.leave()
        }
        thread.name = "crucible.demo.accept"
        thread.start()
        return port
    }

    /// Stops accepting, drops every connection and returns once the port no longer answers.
    func stop() async {
        let (descriptor, open, group) = lock.withLock { () -> (Int32, [DemoSocketConnection], DispatchGroup?) in
            stopped = true
            let current = (listener, Array(connections.values), accepting)
            listener = -1
            accepting = nil
            connections.removeAll()
            return current
        }
        open.forEach { $0.cancel() }
        guard descriptor >= 0, let group else { return }
        shutdown(descriptor, Int32(SHUT_RDWR))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
    }

    /// Binds `descriptor` to an ephemeral port on 127.0.0.1 and listens, returning the port.
    private static func listen(on descriptor: Int32) -> UInt16? {
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Glibc.listen(descriptor, backlog) == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Accepts connections until `stop` shuts the listening socket.
    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let connection = DemoSocketConnection(descriptor: client, handler: handler) { [weak self] closed in self?.forget(closed) }
            let accepted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard accepted else {
                close(client)
                return
            }
            connection.start()
        }
    }

    private func forget(_ connection: DemoSocketConnection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }
}

/// One accepted connection on a thread of its own: reads a request, waits for the handler's response, writes it, and reads
/// the next while the client keeps the connection alive. The thread owns the socket and closes it when it ends.
final class DemoSocketConnection: @unchecked Sendable {
    private static let readSize = 256 * 1024

    private let descriptor: Int32
    private let handler: DemoHTTPServer.Handler
    private let onClose: @Sendable (DemoSocketConnection) -> Void
    private var buffer = Data()

    init(descriptor: Int32, handler: @escaping DemoHTTPServer.Handler, onClose: @escaping @Sendable (DemoSocketConnection) -> Void) {
        self.descriptor = descriptor
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        var noDelay: Int32 = 1
        setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        let thread = Thread { [self] in
            serve()
            close(descriptor)
            onClose(self)
        }
        thread.name = "crucible.demo.connection"
        thread.start()
    }

    /// Wakes the connection's thread out of any read or write, so it ends and closes the socket.
    func cancel() {
        shutdown(descriptor, Int32(SHUT_RDWR))
    }

    private func serve() {
        while true {
            switch DemoRequestParser.parse(buffer) {
            case .incomplete:
                guard read() else { return }
            case .malformed:
                _ = write(DemoResponse(status: 400).head(length: 0, keepAlive: false))
                return
            case .request(let request, let keepAlive, let consumed):
                buffer = Data(buffer.dropFirst(consumed))
                let response = respond(to: request)
                if let stream = response.stream {
                    send(stream, head: response.head(length: nil, keepAlive: false))
                    return
                }
                var payload = response.head(length: response.body.count, keepAlive: keepAlive)
                if !request.isHead { payload.append(response.body) }
                guard write(payload), keepAlive else { return }
            }
        }
    }

    /// Reads what the client sent into the buffer; false once the client is gone.
    private func read() -> Bool {
        var chunk = [UInt8](repeating: 0, count: Self.readSize)
        while true {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                return true
            }
            if count < 0, errno == EINTR { continue }
            return false
        }
    }

    /// Writes all of `data`; false when the client went away.
    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Glibc.send(descriptor, base + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    /// The handler's response to `request`, waited for on this connection's thread, which is not one the handler runs on.
    private func respond(to request: DemoRequest) -> DemoResponse {
        let done = DispatchSemaphore(value: 0)
        let box = DemoResponseBox()
        let handler = handler
        Task {
            box.response = await handler(request)
            done.signal()
        }
        done.wait()
        return box.response ?? DemoResponse(status: 500)
    }

    /// Sends the head, then each chunk of `stream` as it comes, until the stream ends or the client goes away, which the read
    /// this thread keeps open meanwhile notices.
    private func send(_ stream: AsyncStream<Data>, head: Data) {
        guard write(head) else { return }
        let descriptor = descriptor
        let writer = Task { [self] in
            for await chunk in stream {
                guard !Task.isCancelled, write(chunk) else { break }
            }
            shutdown(descriptor, Int32(SHUT_RDWR))
        }
        while read() { buffer.removeAll(keepingCapacity: true) }
        writer.cancel()
        let finished = DispatchSemaphore(value: 0)
        Task {
            await writer.value
            finished.signal()
        }
        finished.wait()
    }
}

/// The response a connection's thread waits for, handed over from the task that made it.
private final class DemoResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DemoResponse?

    var response: DemoResponse? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
#endif
