import CrucibleCore
import Foundation

/// The real shapes of the artwork the app has loaded, height over width by image path, remembered on disk per server so a grid
/// lays out in the shape its artwork really has from the first frame of its next visit. `ImageLoader` records every image it
/// decodes; grids read the shapes through `ArtworkShapeTracker`, which re-lays them out when new ones arrive.
@MainActor
package final class ArtworkShapes {
    package static let shared = ArtworkShapes()

    /// Enough for every poster of a large server; past it the oldest half of what is remembered is dropped.
    private static let capacity = 20_000
    private static let notifyDelay = Duration.milliseconds(150)
    private static let saveDelay = Duration.seconds(2)

    private var shapes: [String: Double] = [:]
    private var order: [String] = []
    private var namespace: String?
    private let trackers = NSHashTable<ArtworkShapeTracker>.weakObjects()
    private var notifyTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private init() {}

    package func shape(of path: String) -> Double? {
        shapes[path]
    }

    /// Switches to the shapes remembered for the server `namespace` names, saving the previous server's first.
    package func use(namespace: String) {
        guard namespace != self.namespace else { return }
        if self.namespace != nil { saveNow() }
        self.namespace = namespace
        let loaded = Self.fileURL(namespace: namespace).flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        shapes = loaded
        order = Array(loaded.keys)
        notifySoon()
    }

    /// Remembers `shape` for `path`; trackers hear about it once a burst of loads has settled.
    package func record(_ shape: Double, for path: String) {
        guard shape.isFinite, shape > 0, shapes[path] != shape else { return }
        if shapes[path] == nil { order.append(path) }
        shapes[path] = shape
        if order.count > Self.capacity { forgetOldestHalf() }
        notifySoon()
        saveSoon()
    }

    func register(_ tracker: ArtworkShapeTracker) {
        trackers.add(tracker)
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
            trackers.allObjects.forEach { $0.shapesDidChange() }
        }
    }

    private func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let namespace, let url = Self.fileURL(namespace: namespace), let data = try? JSONEncoder().encode(shapes) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func fileURL(namespace: String) -> URL? {
        let name = namespace.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        guard !name.isEmpty else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ArtworkShapes", isDirectory: true)
            .appendingPathComponent("\(name).json")
    }
}

/// Keeps one grid in the shape most of its artwork has: `samples` names each card's image and the shape its kind of item has,
/// `aspect` is the shape `ArtworkAspect` settles on with every measurement known so far, and `onChange` runs when images that
/// load later change it, so the grid can re-lay itself out.
@MainActor
package final class ArtworkShapeTracker {
    package private(set) var aspect = ArtworkAspect.poster
    private let samples: @MainActor () -> [ArtworkAspect.Sample]
    private let onChange: @MainActor () -> Void

    package init(samples: @escaping @MainActor () -> [ArtworkAspect.Sample], onChange: @escaping @MainActor () -> Void) {
        self.samples = samples
        self.onChange = onChange
        ArtworkShapes.shared.register(self)
    }

    /// Recomputes the shape from the grid's current cards; true when it changed.
    @discardableResult
    package func update() -> Bool {
        let shapes = ArtworkShapes.shared
        let next = ArtworkAspect.dominant(samples(), measured: shapes.shape(of:))
        guard next != aspect else { return false }
        aspect = next
        return true
    }

    func shapesDidChange() {
        if update() { onChange() }
    }
}
