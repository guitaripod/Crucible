import Foundation

/// Waits a short while for work a screen would rather show in its first pass, without ever holding the screen up for it.
package enum Settle {
    /// The value of `task` when it finishes within `limit`, otherwise nil while the task keeps running for a later update.
    package static func value<Value: Sendable>(of task: Task<Value, Never>, within limit: Duration) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// How long a detail page waits for its integrations once its own data is in.
    package static let detailGrace: Duration = .milliseconds(600)
}
