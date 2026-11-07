import AVKit
import CrucibleCore
import Foundation
import MediaPlayer

/// Connects the system remote commands (lock screen, Control Center, headset and Siri Remote
/// buttons) to a playback session. The commands are process-wide, so a session owns them only
/// between `init` and `tearDown()`, which removes this session's handlers alone: the next episode's
/// session installs its own before the one it replaces is stopped.
@MainActor
final class PlaybackRemoteCommands {
    enum Action: Sendable {
        case play
        case pause
        case togglePlayPause
        case skip(by: Double)
        case seek(to: Double)
        case nextTrack
        case rate(Float)
    }

    private let handler: @MainActor @Sendable (Action) -> Void
    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    init(supportsNextTrack: Bool, handler: @escaping @MainActor @Sendable (Action) -> Void) {
        self.handler = handler
        configure(supportsNextTrack: supportsNextTrack)
    }

    private func configure(supportsNextTrack: Bool) {
        let center = MPRemoteCommandCenter.shared()
        let handler = self.handler

        add(center.playCommand) { @Sendable _ in
            Task { @MainActor in handler(.play) }
            return .success
        }
        add(center.pauseCommand) { @Sendable _ in
            Task { @MainActor in handler(.pause) }
            return .success
        }
        add(center.togglePlayPauseCommand) { @Sendable _ in
            Task { @MainActor in handler(.togglePlayPause) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Preferences.skipForwardSeconds)]
        add(center.skipForwardCommand) { @Sendable event in
            guard let skip = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let interval = skip.interval
            Task { @MainActor in handler(.skip(by: interval)) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Preferences.skipBackSeconds)]
        add(center.skipBackwardCommand) { @Sendable event in
            guard let skip = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let interval = skip.interval
            Task { @MainActor in handler(.skip(by: -interval)) }
            return .success
        }
        add(center.changePlaybackPositionCommand) { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in handler(.seek(to: position)) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = AVPlaybackSpeed.systemDefaultSpeeds.map { NSNumber(value: $0.rate) }
        add(center.changePlaybackRateCommand) { @Sendable event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor in handler(.rate(rate)) }
            return .success
        }
        center.nextTrackCommand.isEnabled = supportsNextTrack
        add(center.nextTrackCommand) { @Sendable _ in
            Task { @MainActor in handler(.nextTrack) }
            return .success
        }
    }

    private func add(_ command: MPRemoteCommand, _ handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        targets.append((command, command.addTarget(handler: handler)))
    }

    func tearDown() {
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets.removeAll()
    }
}
