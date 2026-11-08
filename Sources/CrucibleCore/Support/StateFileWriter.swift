import Foundation

/// Writes small state files away from the main actor. Each write carries the order it was asked in, so a write that runs
/// late never replaces a newer one, and a removal wins over every write asked for before it.
package actor StateFileWriter {
    package static let shared = StateFileWriter()

    private var newest: [URL: Int] = [:]

    package func write<Value: Encodable & Sendable>(_ value: Value, to url: URL, order: Int) {
        guard order > newest[url, default: -1] else { return }
        newest[url] = order
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    package func remove(_ url: URL, order: Int) {
        guard order > newest[url, default: -1] else { return }
        newest[url] = order
        try? FileManager.default.removeItem(at: url)
    }
}
