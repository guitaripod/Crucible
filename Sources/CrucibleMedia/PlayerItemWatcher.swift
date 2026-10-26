import AVFoundation
import CrucibleCore
import Foundation

/// Watches one `AVPlayerItem` for the things a session reacts to: reaching the end, failing (at load
/// or mid-playback), the playhead jumping and, on a transcode, segments arriving or being refused, and
/// playback stalling. Every callback arrives on the main actor.
@MainActor
final class PlayerItemWatcher {
    enum Event: Sendable {
        case ended
        case failed(String)
        case jumped
        case segmentLoaded
        case segmentRefused(status: Int)
        case stalled
    }

    private var statusObservation: NSKeyValueObservation?
    private var observers: [any NSObjectProtocol] = []

    init(item: AVPlayerItem, isTranscode: Bool, handler: @escaping @MainActor @Sendable (Event) -> Void) {
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
        observe(AVPlayerItem.failedToPlayToEndTimeNotification, of: item) { notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let message = PlaybackFailurePolicy.describe(
                domain: error?.domain,
                code: error?.code,
                description: error?.localizedDescription,
                unknown: "failed to play to end"
            )
            Task { @MainActor in handler(.failed(message)) }
        }
        observe(.AVPlayerItemDidPlayToEndTime, of: item) { _ in
            Task { @MainActor in handler(.ended) }
        }
        observe(AVPlayerItem.timeJumpedNotification, of: item) { _ in
            Task { @MainActor in handler(.jumped) }
        }
        guard isTranscode else { return }
        observe(AVPlayerItem.newAccessLogEntryNotification, of: item) { _ in
            Task { @MainActor in handler(.segmentLoaded) }
        }
        observe(AVPlayerItem.newErrorLogEntryNotification, of: item) { notification in
            let status = (notification.object as? AVPlayerItem)?.errorLog()?.events.last?.errorStatusCode ?? 0
            Task { @MainActor in handler(.segmentRefused(status: status)) }
        }
        observe(AVPlayerItem.playbackStalledNotification, of: item) { _ in
            Task { @MainActor in handler(.stalled) }
        }
    }

    private func observe(_ name: Notification.Name, of item: AVPlayerItem, _ block: @escaping @Sendable (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main, using: block))
    }

    func invalidate() {
        statusObservation?.invalidate()
        statusObservation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
