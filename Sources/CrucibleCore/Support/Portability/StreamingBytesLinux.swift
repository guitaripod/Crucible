#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

extension URLSession {
    /// The body of a response as it arrives, byte by byte, for a stream that never ends (server events).
    package struct StreamedBytes: AsyncSequence, Sendable {
        package typealias Element = UInt8
        fileprivate let stream: AsyncThrowingStream<UInt8, Error>

        package func makeAsyncIterator() -> AsyncThrowingStream<UInt8, Error>.AsyncIterator {
            stream.makeAsyncIterator()
        }
    }

    /// Linux stand-in for `bytes(for:)`, which swift-corelibs-foundation lacks: a delegate data task that hands each
    /// chunk on as it arrives and is cancelled when the reader stops. The cancel runs on the session's serial delegate
    /// queue and only while the task is still running: corelibs traps when a task that already completed is cancelled
    /// from another thread.
    package func bytes(for request: URLRequest) async throws -> (StreamedBytes, URLResponse) {
        let relay = StreamRelay()
        let session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            relay.bytes = continuation
            continuation.onTermination = { _ in
                session.delegateQueue.addOperation {
                    guard relay.markFinished() else { return }
                    task.cancel()
                }
            }
        }
        let response = try await withCheckedThrowingContinuation { continuation in
            relay.response = continuation
            task.resume()
        }
        return (StreamedBytes(stream: stream), response)
    }
}

private final class StreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var bytesContinuation: AsyncThrowingStream<UInt8, Error>.Continuation?
    private var finished = false

    /// Marks the task finished; returns whether it was still running.
    func markFinished() -> Bool {
        lock.withLock {
            defer { finished = true }
            return !finished
        }
    }

    var response: CheckedContinuation<URLResponse, Error>? {
        get { lock.withLock { responseContinuation } }
        set { lock.withLock { responseContinuation = newValue } }
    }

    var bytes: AsyncThrowingStream<UInt8, Error>.Continuation? {
        get { lock.withLock { bytesContinuation } }
        set { lock.withLock { bytesContinuation = newValue } }
    }

    private func takeResponse() -> CheckedContinuation<URLResponse, Error>? {
        lock.withLock {
            let pending = responseContinuation
            responseContinuation = nil
            return pending
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        takeResponse()?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let bytes else { return }
        for byte in data { bytes.yield(byte) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        _ = markFinished()
        if let pending = takeResponse() {
            pending.resume(throwing: error ?? URLError(.badServerResponse))
        }
        bytes?.finish(throwing: error)
        session.finishTasksAndInvalidate()
    }
}
#endif
