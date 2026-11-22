import CrucibleCore
import Foundation
import Kiln

/// A scan through the title from something other than a pointer on the scrubber: a held d-pad or arrow key, the
/// gamepad's triggers, or the wheel and a touchpad (a Steam Deck trackpad set to scroll). The playhead, its time and the
/// preview still move at the display's rate; the picture follows by keyframe seeks, one at a time, when seeks on this file
/// land quickly, and is held paused meanwhile; letting go seeks exactly once, to where the scan stopped, and plays on if
/// it was playing. Every press of a held d-pad used to be an exact seek of two seconds with the title playing, each one
/// decoding from a keyframe, so a long press stuttered along instead of gliding.
@MainActor
final class PlayerScan {
    enum Source: Equatable {
        /// A held d-pad or arrow key, forward or back.
        case hold(forward: Bool)
        case triggers
        case wheel
    }

    let source: Source
    let origin: Double
    let resumes: Bool
    private(set) var target: Double
    let began = Window.now()
    /// When the input last said it is still going: a key's repeat, a trigger's pull, a wheel's notch.
    var lastInput = Window.now()
    var task: Task<Void, Never>?
    /// Where the last keyframe seek went, so one is sent only when the target has moved a frame's worth.
    var seekedTo: Double?

    init(source: Source, origin: Double, target: Double, resumes: Bool) {
        self.source = source
        self.origin = origin
        self.target = target
        self.resumes = resumes
    }

    func move(to value: Double, duration: Double) {
        target = min(max(value, 0), max(duration - 1, 0))
    }

    /// How fast a held d-pad moves through a title of `duration` after being held `held` seconds, in seconds of the title a
    /// second: ten at first, then speeding up over three seconds to a fortieth of the title (at least a minute), so a short
    /// hold finds a moment and a long one crosses a film.
    static func holdSpeed(held: Double, duration: Double) -> Double {
        let fastest = max(60, duration / 40)
        let ramp = min(max((held - 0.4) / 2.6, 0), 1)
        return 10 + (fastest - 10) * ramp * ramp
    }

    /// How long a source may go quiet before the scan counts as let go: a held key repeats every 45 to 160 ms, the wheel
    /// and a touchpad come in bursts.
    var patience: Double {
        switch source {
        case .hold: 0.26
        case .triggers: .infinity
        case .wheel: 0.4
        }
    }
}

extension PlayerScreen {
    /// Starts a scan from `source`, or carries on the one under way when it is the same input.
    @discardableResult
    func beginScan(_ source: PlayerScan.Source, from start: Double) -> PlayerScan? {
        guard player != nil, duration > 0 else { return nil }
        if let scan, scan.source == source { return scan }
        if scan != nil { endScan() }
        let resumes = player?.state.isPaused == false
        if resumes { player?.setPausedLater(true) }
        let started = PlayerScan(source: source, origin: position, target: start, resumes: resumes)
        started.move(to: start, duration: duration)
        scan = started
        viewerActed()
        stills?.prepare()
        showChrome(autoHide: false)
        showScanTarget(started)
        started.task = Task { [weak self, weak started] in
            var last = Window.now()
            while !Task.isCancelled, let self, let started, self.scan === started {
                try? await Task.sleep(for: .milliseconds(16))
                let now = Window.now()
                if now - started.lastInput > started.patience {
                    self.endScan()
                    return
                }
                self.advance(started, by: now - last, at: now)
                last = now
            }
        }
        return started
    }

    /// Moves a scan that moves on its own (a held d-pad, pulled triggers) by `dt` seconds of the display's time.
    private func advance(_ scan: PlayerScan, by dt: Double, at now: Double) {
        switch scan.source {
        case .hold(let forward):
            let speed = PlayerScan.holdSpeed(held: now - scan.began, duration: duration)
            scan.move(to: scan.target + (forward ? speed : -speed) * dt, duration: duration)
        case .triggers:
            let pull = Double(triggerPull)
            guard pull != 0 else {
                endScan()
                return
            }
            scan.move(to: scan.target + pull * abs(pull) * 90 * dt, duration: duration)
        case .wheel:
            return
        }
        showScanTarget(scan)
    }

    /// Moves a wheel's scan by `seconds` of the title.
    func scanWheel(by seconds: Double) {
        guard let scan = beginScan(.wheel, from: playhead) else { return }
        scan.lastInput = Window.now()
        scan.move(to: scan.target + seconds, duration: duration)
        showScanTarget(scan)
    }

    /// Shows where the scan is and lets the picture follow when this file seeks quickly enough to keep up, else covers it
    /// with the still for that moment.
    private func showScanTarget(_ scan: PlayerScan) {
        transport.showScan(at: Float(scan.target / duration))
        showChrome(autoHide: false)
        if dragMovesPicture {
            guard abs((scan.seekedTo ?? -1) - scan.target) >= 0.04 else { return }
            scan.seekedTo = scan.target
            seek(to: scan.target, mode: .keyframe)
        } else {
            veil(at: scan.target)
        }
    }

    /// Lets go of the scan: one exact seek to where it stopped, playing on if the title was playing.
    func endScan() {
        guard let finished = scan else { return }
        scan = nil
        finished.task?.cancel()
        transport.showScan(at: nil)
        seek(to: finished.target)
        if finished.resumes { player?.setPausedLater(false) }
        noteJump(from: finished.origin, to: finished.target)
        showChrome(autoHide: true)
    }
}
