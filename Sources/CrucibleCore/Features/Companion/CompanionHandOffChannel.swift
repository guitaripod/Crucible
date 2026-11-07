import Foundation
import Network

/// The two ends of a hand-off over a connection DeviceDiscoveryUI opened between an Apple TV and a nearby iPhone: each
/// side writes one line and reads one line. The connection is Apple's encrypted device-to-device link, so the
/// `crucible://pair` link that crosses it is seen by nothing else.
package enum CompanionHandOffChannel {
    package enum Failure: Error, Equatable, Sendable {
        case closed
        case timedOut
        case tooLong
    }

    /// Waits until `connection` is ready, or fails.
    package static func ready(_ connection: NWConnection, queue: DispatchQueue, timeout: Duration = .seconds(30)) async throws(Failure) {
        let state = AsyncStream<Bool> { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield(true)
                case .failed, .cancelled: continuation.yield(false)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        let ready = await withTimeout(timeout, stop: { connection.cancel() }) {
            for await ready in state { return ready }
            return false
        }
        guard let ready else { throw .timedOut }
        guard ready else { throw .closed }
    }

    /// Writes `data` and waits for the system to take it, within `timeout`.
    package static func send(_ data: Data, on connection: NWConnection, timeout: Duration = .seconds(15)) async throws(Failure) {
        let sent = await withTimeout(timeout, stop: { connection.cancel() }) {
            await withCheckedContinuation { continuation in
                connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
            }
        }
        guard let sent else { throw .timedOut }
        guard sent else { throw .closed }
    }

    /// Reads until the first newline, at most `CompanionHandOff.maximumLine` bytes, within `timeout`.
    package static func readLine(from connection: NWConnection, timeout: Duration) async throws(Failure) -> String {
        let outcome: Result<String, Failure>? = await withTimeout(timeout, stop: { connection.cancel() }) {
            var buffer = Data()
            while true {
                let (chunk, complete) = await receive(connection)
                if let chunk { buffer.append(chunk) }
                if let line = CompanionHandOff.firstLine(in: buffer) { return .success(line) }
                if buffer.count > CompanionHandOff.maximumLine { return .failure(.tooLong) }
                if complete || chunk == nil { return .failure(.closed) }
            }
        }
        switch outcome {
        case .success(let line)?: return line
        case .failure(let failure)?: throw failure
        case nil: throw .timedOut
        }
    }

    private static func receive(_ connection: NWConnection) async -> (Data?, Bool) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: CompanionHandOff.maximumLine) { data, _, isComplete, error in
                continuation.resume(returning: (error == nil ? data : nil, isComplete || error != nil))
            }
        }
    }

    /// The result of `work`, or nil when `timeout` passes or the calling task is cancelled first. `stop` must make `work`
    /// return (by cancelling the connection it waits on), since a task group only finishes once every child has.
    private static func withTimeout<Value: Sendable>(_ timeout: Duration, stop: @escaping @Sendable () -> Void, _ work: @escaping @Sendable () async -> Value) async -> Value? {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Value?.self) { group in
                group.addTask { await work() }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { stop() }
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return Task.isCancelled ? nil : first
            }
        } onCancel: {
            stop()
        }
    }
}
