import Foundation

/// Runs one asynchronous operation per key and shares its result between every caller that asks
/// for the same key while it is in flight. Callers are reference-counted: cancelling one waiter
/// leaves the operation running for the others, and cancelling the last waiter cancels the
/// operation itself, so work nobody is waiting for any more (a poster whose cell was reused) stops.
/// Results are not cached; a request after completion starts a new operation.
package actor InFlightCoalescer<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let token: Int
        let task: Task<Value?, Never>
        var waiters: Int
    }

    private var entries: [Key: Entry] = [:]
    private var counter = 0

    package init() {}

    package var inFlightCount: Int { entries.count }

    package func value(for key: Key, operation: @escaping @Sendable () async -> Value?) async -> Value? {
        let token: Int
        let task: Task<Value?, Never>
        if var existing = entries[key] {
            existing.waiters += 1
            entries[key] = existing
            token = existing.token
            task = existing.task
        } else {
            counter &+= 1
            token = counter
            task = Task { [self] in
                let result = await operation()
                finish(key, token: token)
                return result
            }
            entries[key] = Entry(token: token, task: task, waiters: 1)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.waiterCancelled(key, token: token) }
        }
    }

    package func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
        entries.removeAll()
    }

    private func finish(_ key: Key, token: Int) {
        if entries[key]?.token == token {
            entries[key] = nil
        }
    }

    private func waiterCancelled(_ key: Key, token: Int) {
        guard var entry = entries[key], entry.token == token else { return }
        entry.waiters -= 1
        guard entry.waiters <= 0 else {
            entries[key] = entry
            return
        }
        entries[key] = nil
        entry.task.cancel()
    }
}
