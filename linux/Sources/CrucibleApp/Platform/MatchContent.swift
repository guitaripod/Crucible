import CrucibleCore
import Foundation
import Kiln
import MidgarCore

/// Match Content (docs/LINUX.md §7.4): while the player fills the screen, the screen it is on runs at a refresh that shows
/// the title's frames evenly and in HDR for an HDR title, as `MatchContentPlan` decides, and goes back to how it was when
/// playback ends or leaves full screen. HDR goes on with wide colour gamut, as KDE's own HDR switch does (HDR alone leaves
/// KWin's picture grey-green). The state to go back to is written down first and a guard process watches it, so the screen
/// comes back even when Crucible dies mid-title, and a launch puts back what a guard could not.
@MainActor
enum MatchContent {
    /// How the screen was before a title changed it, and whose title it was.
    struct Prior: Codable, Equatable {
        var output: String
        var mode: DisplayControl.Mode
        var hdr: Bool
        var wideColorGamut: Bool
        var owner: ProcessIdentity
    }

    /// A process that survives pid reuse: its pid and the time it started, in clock ticks since boot.
    struct ProcessIdentity: Codable, Equatable {
        var pid: Int32
        var started: UInt64

        static var current: ProcessIdentity? { of(getpid()) }

        static func of(_ pid: Int32) -> ProcessIdentity? {
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = stat.lastIndex(of: ")") else { return nil }
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            guard fields.count > 19, let started = UInt64(fields[19]) else { return nil }
            return ProcessIdentity(pid: pid, started: started)
        }

        var isAlive: Bool { ProcessIdentity.of(pid) == self }
    }

    private static let queue = DispatchQueue(label: "org.guitaripod.Crucible.match-content")
    private static var file: URL { AppPlatform.logsDirectory.appendingPathComponent("display-prior.json") }
    private static var guardProcess: Process?

    /// Matches the screen showing `window` to `stream` when the setting is on and the player fills the screen; a later
    /// title keeps the state the first one found.
    static func engage(_ stream: ResolvedStream, in window: Window) {
        guard Preferences.matchesContent, window.isFullscreen, let owner = ProcessIdentity.current else { return }
        guard let output = window.outputName else {
            MidgarLog.notice("Match Content: the compositor has not said which screen shows the player", category: .playback)
            return
        }
        let video = stream.media?.Part?.first?.Stream?.first { $0.streamType == 1 }
        let frameRate = video?.frameRate
        let isHDR = Self.isHDR(DynamicRange(video), stream: stream)
        let file = file
        let started = startGuard
        queue.async {
            guard let display = DisplayControl() else {
                MidgarLog.notice("Match Content: the compositor has no output management (KWin's), so the screen stays as it is", category: .playback)
                return
            }
            guard let state = display.state(of: output) else {
                MidgarLog.notice("Match Content: no screen named \(output) in KWin's output management", category: .playback)
                return
            }
            let plan = MatchContentPlan.make(frameRate: frameRate, isHDR: isHDR, current: DisplayMode(state.current), modes: state.modes.map(DisplayMode.init),
                                             hdrCapable: state.hdrCapable, hdrOn: state.hdr, adaptiveSync: state.adaptiveSync)
            MidgarLog.notice("Match Content on \(output): \(Self.describe(state)), \(frameRate.map { "\($0) fps" } ?? "no frame rate")\(isHDR ? " HDR" : ""): "
                             + (plan.changesNothing ? "nothing to change" : "refresh \(plan.refreshMilliHertz.map(String.init) ?? "kept"), HDR \(plan.hdr.map { $0 ? "on" : "off" } ?? "kept")"),
                             category: .playback)
            guard !plan.changesNothing else { return }
            if !FileManager.default.fileExists(atPath: file.path) {
                let prior = Prior(output: output, mode: state.current, hdr: state.hdr, wideColorGamut: state.wideColorGamut, owner: owner)
                guard Self.write(prior, to: file) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { started(owner) } }
            }
            let mode = plan.refreshMilliHertz.map { DisplayControl.Mode(width: state.current.width, height: state.current.height, refreshMilliHertz: $0) }
            if !display.apply(to: output, mode: mode, hdr: plan.hdr, wideColorGamut: plan.hdr) {
                MidgarLog.error("KWin did not switch \(output) for the title", category: .playback)
            }
        }
    }

    /// Puts the screen back as it was before the first title changed it.
    static func release() {
        let file = file
        queue.async { Self.restore(from: file) }
    }

    /// A launch after a crash the guard missed (the session ended with it): the screen goes back if its owner is gone.
    static func restoreLeftover() {
        let file = file
        queue.async {
            guard let prior = Self.read(file), !prior.owner.isAlive else { return }
            MidgarLog.notice("Restoring \(prior.output), which a title left switched", category: .playback)
            Self.restore(from: file)
        }
    }

    /// `crucible --display-guard PID STARTED`: waits for the player's process to end and, if it left the screen switched,
    /// puts it back. Ends as soon as the screen is back.
    static func runGuard(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--display-guard"), arguments.count > index + 2, let pid = Int32(arguments[index + 1]),
              let started = UInt64(arguments[index + 2]) else { return 2 }
        let owner = ProcessIdentity(pid: pid, started: started)
        let file = file
        while FileManager.default.fileExists(atPath: file.path) {
            if !owner.isAlive {
                restore(from: file)
                return 0
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return 0
    }

    private static func startGuard(_ owner: ProcessIdentity) {
        if let guardProcess, guardProcess.isRunning { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        process.arguments = ["--display-guard", String(owner.pid), String(owner.started)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            guardProcess = process
        } catch {
            MidgarLog.error("The Match Content guard did not start: \(error.localizedDescription)", category: .playback)
        }
    }

    /// The picture that reaches the screen is HDR: the file's when it plays as it is, the conversion's when the server
    /// converts it.
    static func isHDR(_ range: DynamicRange, stream: ResolvedStream) -> Bool {
        guard !stream.isDirectPlay, let decision = stream.decision, decision.videoDecision == "transcode" else { return range.isHDR }
        return ["smpte2084", "arib-std-b67"].contains(decision.videoTransfer?.lowercased() ?? "")
    }

    private nonisolated static func restore(from file: URL) {
        guard let prior = read(file) else { return }
        guard let display = DisplayControl() else { return }
        if display.apply(to: prior.output, mode: prior.mode, hdr: prior.hdr, wideColorGamut: prior.wideColorGamut) {
            try? FileManager.default.removeItem(at: file)
            MidgarLog.notice("Put \(prior.output) back to \(prior.mode.width)x\(prior.mode.height) at \(prior.mode.refreshMilliHertz) mHz, HDR \(prior.hdr ? "on" : "off")",
                             category: .playback)
        } else {
            MidgarLog.error("KWin did not put \(prior.output) back; the next launch tries again", category: .playback)
        }
    }

    private nonisolated static func read(_ file: URL) -> Prior? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Prior.self, from: data)
    }

    private nonisolated static func write(_ prior: Prior, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(prior).write(to: file, options: .atomic)
            return true
        } catch {
            MidgarLog.error("Match Content could not keep the screen's state: \(error.localizedDescription)", category: .playback)
            return false
        }
    }

    private nonisolated static func describe(_ state: DisplayControl.State) -> String {
        "\(state.current.width)x\(state.current.height) at \(state.current.refreshMilliHertz) mHz, \(state.modes.count) modes, HDR "
            + (state.hdr ? "on" : state.hdrCapable ? "off" : "unsupported") + (state.adaptiveSync ? ", variable refresh" : "")
    }
}

private extension DisplayMode {
    init(_ mode: DisplayControl.Mode) {
        self.init(width: mode.width, height: mode.height, refreshMilliHertz: mode.refreshMilliHertz)
    }
}
