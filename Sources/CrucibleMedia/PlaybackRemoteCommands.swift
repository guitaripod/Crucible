import CrucibleCore
import Foundation
import MediaPlayer

/// Connects the system remote commands (lock screen, Control Center, headset and Siri Remote
/// buttons) to a playback session. The commands are process-wide, so a session owns them only
/// between `init` and `tearDown()`.
@MainActor
final class PlaybackRemoteCommands {
    enum Action: Sendable {
        case play
        case pause
        case togglePlayPause
        case skip(by: Double)
        case seek(to: Double)
        case nextTrack
    }

    private let handler: @MainActor @Sendable (Action) -> Void

    init(supportsNextTrack: Bool, handler: @escaping @MainActor @Sendable (Action) -> Void) {
        self.handler = handler
        configure(supportsNextTrack: supportsNextTrack)
    }

    private func configure(supportsNextTrack: Bool) {
        let center = MPRemoteCommandCenter.shared()
        let handler = self.handler

        center.playCommand.addTarget { @Sendable _ in
            Task { @MainActor in handler(.play) }
            return .success
        }
        center.pauseCommand.addTarget { @Sendable _ in
            Task { @MainActor in handler(.pause) }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable _ in
            Task { @MainActor in handler(.togglePlayPause) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Preferences.skipForwardSeconds)]
        center.skipForwardCommand.addTarget { @Sendable event in
            guard let skip = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let interval = skip.interval
            Task { @MainActor in handler(.skip(by: interval)) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Preferences.skipBackSeconds)]
        center.skipBackwardCommand.addTarget { @Sendable event in
            guard let skip = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            let interval = skip.interval
            Task { @MainActor in handler(.skip(by: -interval)) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in handler(.seek(to: position)) }
            return .success
        }
        center.nextTrackCommand.isEnabled = supportsNextTrack
        center.nextTrackCommand.addTarget { @Sendable _ in
            Task { @MainActor in handler(.nextTrack) }
            return .success
        }
    }

    func tearDown() {
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.skipForwardCommand, center.skipBackwardCommand,
            center.changePlaybackPositionCommand, center.nextTrackCommand,
        ]
        commands.forEach { $0.removeTarget(nil) }
    }
}
