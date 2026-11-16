import Foundation
import Kiln

/// The real shapes of the artwork loaded so far, height over width by server path, remembered on disk per server so a grid
/// lays out in the shape its artwork really has from the first frame of its next visit (`ArtworkShapes` on the Apple TV).
/// Every artwork slot records what it decodes; observers hear about it once a burst of loads has settled.
@MainActor
public final class ArtworkShapes {
    public static let shared = ArtworkShapes()

    /// Enough for every poster of a large server; past it the oldest half of what is remembered is dropped.
    private static let capacity = 20_000
    private static let notifyDelay = Duration.milliseconds(150)
    private static let saveDelay = Duration.seconds(2)

    private final class Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void

        init(owner: AnyObject, handler: @escaping @MainActor () -> Void) {
            self.owner = owner
            self.handler = handler
        }
    }

    private var shapes: [String: Double] = [:]
    private var order: [String] = []
    private var file: URL?
    private var observers: [Observer] = []
    private var notifyTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private init() {}

    public func shape(of path: String) -> Double? {
        shapes[path]
    }

    /// Switches to the shapes remembered in `file` (one per server), saving the previous server's first.
    public func use(file: URL) {
        guard file != self.file else { return }
        if self.file != nil { saveNow() }
        self.file = file
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        shapes = loaded
        order = Array(loaded.keys)
        notifySoon()
    }

    /// Remembers `shape` for `path`; observers hear about it once a burst of loads has settled.
    public func record(_ shape: Double, for path: String) {
        guard shape.isFinite, shape > 0, shapes[path] != shape else { return }
        if shapes[path] == nil { order.append(path) }
        shapes[path] = shape
        if order.count > Self.capacity { forgetOldestHalf() }
        notifySoon()
        saveSoon()
    }

    /// Calls `handler` whenever measured shapes change, for as long as `owner` lives.
    public func observe(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// Records the shape of a texture decoded for `source`; only server paths are remembered, since only they come back.
    func record(_ texture: Texture, for source: ArtworkSource) {
        guard case .path(let path, _) = source, texture.width > 0, texture.height > 0 else { return }
        record(Double(texture.height) / Double(texture.width), for: path)
    }

    private func forgetOldestHalf() {
        let dropped = order.prefix(order.count / 2)
        dropped.forEach { shapes[$0] = nil }
        order.removeFirst(dropped.count)
    }

    private func notifySoon() {
        guard notifyTask == nil else { return }
        notifyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.notifyDelay)
            guard let self else { return }
            notifyTask = nil
            observers.removeAll { $0.owner == nil }
            observers.forEach { $0.handler() }
        }
    }

    private func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            self?.saveNow()
        }
    }

    /// Writes the shapes off the main thread, encoding included: the dictionary can hold thousands of entries and a save
    /// comes every couple of seconds while a long library scrolls in its artwork.
    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let file else { return }
        let snapshot = shapes
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
