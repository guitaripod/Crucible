import AVFoundation
import CrucibleCore
import Foundation

/// Watches one `AVPlayerItem` for the things a session reacts to: reaching the end, failing (at load
/// or mid-playback) and, on a transcode, the playhead jumping. Every callback arrives on the main actor.
@MainActor
final class PlayerItemWatcher {
    enum Event: Sendable {
        case ended
        case failed(String)
        case jumped
    }

    private var statusObservation: NSKeyValueObservation?
    private var observers: [any NSObjectProtocol] = []

    init(item: AVPlayerItem, observesJumps: Bool, handler: @escaping @MainActor @Sendable (Event) -> Void) {
        statusObservation = item.observe(\.status, options: [.new]) { @Sendable observedItem, _ in
            guard observedItem.status == .failed else { return }
            let error = observedItem.error as NSError?
            let message = PlaybackFailurePolicy.describe(
                domain: error?.domain,
                code: error?.code,
                description: observedItem.error?.localizedDescription,
                unknown: "unknown"
            )
            Task { @MainActor in handler(.failed(message)) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let message = PlaybackFailurePolicy.describe(
                domain: error?.domain,
                code: error?.code,
                description: error?.localizedDescription,
                unknown: "failed to play to end"
            )
            Task { @MainActor in handler(.failed(message)) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in handler(.ended) }
        })
        if observesJumps {
            observers.append(NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification,
                object: item,
                queue: .main
            ) { _ in
                Task { @MainActor in handler(.jumped) }
            })
        }
    }

    func invalidate() {
        statusObservation?.invalidate()
        statusObservation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
