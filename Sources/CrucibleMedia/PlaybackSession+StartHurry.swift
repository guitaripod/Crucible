import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore

extension PlaybackSession {
    /// A start, a jump or a rebuilt stream is about to show its picture. The player's own caution holds a start back
    /// until it believes the stream will never stall, which on a stream of 15 or 20 megabits a second can be many seconds
    /// with seconds of it already loaded; a viewer who pressed Play or let go of the scrubber wants the picture. So for
    /// the next few seconds the player is watched, and told to play what it has the moment a little of the stream is
    /// loaded. Once only: a stall after that is the player's to wait out, as in any other playback. `place` is where on the
    /// player's clock the picture is expected, when the player is on its way there: until its clock reads that place it
    /// is left alone, since what it has loaded is still the stretch it is leaving.
    func expectPicture(at place: Double? = nil) {
        hurryTask?.cancel()
        let deadline = now().advanced(by: PlaybackTiming.startHurryWindow)
        let began = now()
        hurryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, !isStopped, now() < deadline else { return }
                if hurry(at: place, waitingSince: began) { return }
            }
        }
    }

    /// One look at a player expected to show its picture. Returns whether it was told to play what it has.
    private func hurry(at place: Double?, waitingSince began: ContinuousClock.Instant) -> Bool {
        guard let player, let item = player.currentItem, item.status == .readyToPlay, !isRestarting,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate, player.reasonForWaitingToPlay != .noItemToPlay else { return false }
        let position = item.currentTime().seconds
        if let place, abs(position - place) > 2 { return false }
        guard position.isFinite, let loaded = item.loadedRanges.first(where: { $0.contains(position) || abs($0.lowerBound - position) < 1 }) else { return false }
        let ahead = loaded.upperBound - max(position, loaded.lowerBound)
        let duration = item.duration.seconds
        let reachesEnd = duration.isFinite && loaded.upperBound >= duration - 0.5
        guard ahead >= PlaybackTiming.startBuffer || reachesEnd else { return false }
        let waited = Int((began.duration(to: now()).seconds * 1000).rounded())
        MidgarLog.notice("Start hurried ratingKey=\(request.ratingKey): \(String(format: "%.1f", ahead)) s loaded after \(waited) ms", category: .playback)
        player.playImmediately(atRate: player.rate > 0 ? player.rate : 1)
        return true
    }
}
