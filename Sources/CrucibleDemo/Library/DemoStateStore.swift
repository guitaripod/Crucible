import Foundation
import os

/// Keeps the demo's watch state in a small JSON file in Application Support, written a moment after the last change.
final class DemoStateStore: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "demo")
    private static let delay: TimeInterval = 0.4

    let fileURL: URL?

    private let queue = DispatchQueue(label: "com.guitaripod.crucible.demo.state", qos: .utility)
    private var pending: DemoPersistedState?
    private var scheduled: DispatchWorkItem?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CrucibleDemo", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// The saved state, or an empty one when there is no file or it cannot be read.
    func load() -> DemoPersistedState {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return DemoPersistedState() }
        guard let state = try? JSONDecoder().decode(DemoPersistedState.self, from: data), state.version == 1 else {
            Self.log.error("Demo state could not be read; starting fresh")
            return DemoPersistedState()
        }
        return state
    }

    func scheduleSave(_ state: DemoPersistedState) {
        queue.async { [self] in
            pending = state
            scheduled?.cancel()
            let work = DispatchWorkItem { [self] in writePending() }
            scheduled = work
            queue.asyncAfter(deadline: .now() + Self.delay, execute: work)
        }
    }

    /// Writes any change that is still waiting and returns once it is on disk.
    func flush() {
        queue.sync {
            scheduled?.cancel()
            scheduled = nil
            writePending()
        }
    }

    private func writePending() {
        guard let state = pending, let fileURL else { return }
        pending = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = fileURL
            try? url.setResourceValues(values)
        } catch {
            Self.log.error("Demo state could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
