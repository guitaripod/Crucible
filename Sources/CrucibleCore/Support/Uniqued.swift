import Foundation

extension Sequence {
    /// The elements in their original order with every later element that repeats an earlier
    /// `id` dropped. Diffable data sources and `Dictionary(uniqueKeysWithValues:)` trap on
    /// duplicate identifiers, so lists built from server data go through this first.
    package func uniqued<ID: Hashable>(by id: (Element) -> ID) -> [Element] {
        var seen = Set<ID>()
        return filter { seen.insert(id($0)).inserted }
    }
}

/// Remembers when something was last loaded so a screen that reappears (a pop back from a
/// sub-screen) can skip a reload that would only repeat the last answer.
package struct ReloadThrottle: Sendable {
    package let interval: TimeInterval
    private var loadedAt: Date?

    package init(interval: TimeInterval) {
        self.interval = interval
    }

    package func isFresh(now: Date = Date()) -> Bool {
        guard let loadedAt else { return false }
        return now.timeIntervalSince(loadedAt) < interval
    }

    package mutating func markLoaded(at now: Date = Date()) {
        loadedAt = now
    }

    package mutating func invalidate() {
        loadedAt = nil
    }
}
