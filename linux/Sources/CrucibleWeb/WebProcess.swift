import Foundation

/// Runs a command to its end on threads of its own and hands back what it wrote.
///
/// Foundation's `Process` on Linux hands a pipe made on one thread to a child spawned on another unless both happen under
/// one lock, and keeps a finished process and its pipes until `waitUntilExit()` is called. This runner does both, and
/// reads the two pipes on plain threads, so a slow command never holds one of the concurrency pool's.
package enum WebProcess {
    package struct Output: Sendable {
        package let status: Int32
        package let standardOutput: Data
        package let standardError: String

        package init(status: Int32, standardOutput: Data, standardError: String) {
            self.status = status
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    package enum Failure: Error, Equatable, Sendable {
        case launch(String)
        case timedOut
    }

    /// Runs `executable` with `arguments` and waits for it to end. A cancelled task or a command still running after
    /// `timeout` is terminated, and killed should it ignore that.
    package static func run(_ executable: URL, arguments: [String], timeout: Duration = .seconds(60)) async throws -> Output {
        let job = Job()
        let output: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                threads.async {
                    continuation.resume(with: Result { try job.run(executable, arguments: arguments, timeout: timeout) })
                }
            }
        } onCancel: {
            job.stop()
        }
        try Task.checkCancellation()
        return output
    }

    fileprivate static let threads = DispatchQueue(label: "org.guitaripod.Crucible.web-process", attributes: .concurrent)
    fileprivate static let spawning = NSLock()
}

/// One command's run: the process, and whether it was stopped or ran out of time.
private final class Job: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var timedOut = false

    func run(_ executable: URL, arguments: [String], timeout: Duration) throws -> WebProcess.Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipes = try spawn(process)
        let expiry = DispatchWorkItem { [weak self] in self?.expire() }
        WebProcess.threads.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000)), execute: expiry)
        let errors = Collected()
        let reading = DispatchGroup()
        WebProcess.threads.async(group: reading) { errors.data = pipes.error.fileHandleForReading.readDataToEndOfFile() }
        let written = pipes.output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        expiry.cancel()
        try? pipes.output.fileHandleForReading.close()
        try? pipes.error.fileHandleForReading.close()
        let ranOut = lock.withLock {
            self.process = nil
            return timedOut
        }
        if ranOut { throw WebProcess.Failure.timedOut }
        return WebProcess.Output(status: process.terminationStatus, standardOutput: written,
                                 standardError: String(decoding: errors.data, as: UTF8.self))
    }

    /// Makes the pipes and starts the process under the lock every spawn shares.
    private func spawn(_ process: Process) throws -> (output: Pipe, error: Pipe) {
        try WebProcess.spawning.withLock {
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            let alreadyStopped = lock.withLock { stopped }
            if alreadyStopped { throw CancellationError() }
            do {
                try process.run()
            } catch {
                throw WebProcess.Failure.launch(String(describing: error))
            }
            lock.withLock { self.process = process }
            return (output, error)
        }
    }

    func stop() {
        let running = lock.withLock {
            stopped = true
            return process
        }
        if let running { end(running) }
    }

    private func expire() {
        let running = lock.withLock {
            guard process != nil else { return nil as Process? }
            timedOut = true
            return process
        }
        if let running { end(running) }
    }

    /// Asks the process to end, and kills it three seconds later if it is still there.
    private func end(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let identifier = process.processIdentifier
        WebProcess.threads.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let alive = self.lock.withLock { self.process != nil }
            if alive { kill(identifier, SIGKILL) }
        }
    }
}

private final class Collected: @unchecked Sendable {
    var data = Data()
}
