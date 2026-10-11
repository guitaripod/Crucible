import Foundation

/// Owns one unit of asynchronous work for a screen. `run` cancels whatever the slot ran before, and a
/// slot made by `TVScreenViewController.makeTaskSlot()` is cancelled when the screen disappears
/// unless its work was started with `.keepAlive` (a mark-watched request that must finish even if the
/// user leaves).
@MainActor
final class TVTaskSlot {
    enum Lifetime {
        case screen
        case keepAlive
    }

    private var task: Task<Void, Never>?
    private var lifetime = Lifetime.screen

    var isRunning: Bool { task != nil && !(task?.isCancelled ?? true) }

    deinit { task?.cancel() }

    func run(_ lifetime: Lifetime = .screen, _ operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        self.lifetime = lifetime
        task = Task { @MainActor in
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func cancelUnlessKeptAlive() {
        guard lifetime == .screen else { return }
        cancel()
    }
}
