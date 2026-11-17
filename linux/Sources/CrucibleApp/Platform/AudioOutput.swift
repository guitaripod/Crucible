import CrucibleCore
import Foundation
import MidgarCore

/// The sound output before a play (docs/LINUX.md §7.6): PipeWire's default sink read with `pw-dump`, its IEC958 codecs
/// set again with `pw-cli` when PipeWire forgot them on a reconnect, the sink's own choice kept for that, and mpv's
/// `audio-spdif` list, so TrueHD with Atmos, DTS-HD and Dolby Digital reach the receiver as bitstreams; and how many
/// channels the sink plays, which Volume Boost mixes down to ahead of its limiter.
enum AudioOutput {
    struct Output: Equatable {
        /// mpv's `audio-spdif` codecs, empty to decode everything.
        var spdif: [String]
        /// How many channels the default sink plays, nil when PipeWire did not say.
        var channels: Int?
    }

    /// The output for `setting`; off the main thread.
    static func prepare(_ setting: AudioPassthrough) async -> Output {
        await Task.detached(priority: .userInitiated) { plan(setting) }.value
    }

    private static func plan(_ setting: AudioPassthrough) -> Output {
        guard let dump = run("pw-dump", []) else {
            MidgarLog.notice("PipeWire did not answer pw-dump; audio is decoded", category: .playback)
            return Output(spdif: [], channels: nil)
        }
        let sink = PipeWireSink.defaultSink(inDump: dump)
        let key = sink.map { "audio.iec958.\($0.name)" }
        let plan = AudioPassthroughPlan.make(setting, sink: sink, remembered: key.flatMap { UserDefaults.standard.stringArray(forKey: $0) })
        if let key, let remember = plan.remember { UserDefaults.standard.set(remember, forKey: key) }
        if let sink, let codecs = plan.reapply {
            let applied = run("pw-cli", ["set-param", String(sink.id), "Props", "{ iec958Codecs: [ \(codecs.joined(separator: " ")) ] }"]) != nil
            MidgarLog.notice("Set \(sink.name)'s IEC958 codecs to \(codecs.joined(separator: " "))\(applied ? "" : " (pw-cli failed)")", category: .playback)
        }
        let channels = sink?.channels.map(String.init) ?? "unknown"
        MidgarLog.notice("Audio passthrough \(setting) on \(sink?.name ?? "no sink") (channels: \(channels)): \(plan.spdif.isEmpty ? "decoded" : plan.spdif.joined(separator: ","))",
                         category: .playback)
        return Output(spdif: plan.spdif, channels: sink?.channels)
    }

    /// Runs a PipeWire tool from the path and returns what it printed, or nil when it failed or took over three seconds.
    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin").split(separator: ":").map(String.init)
        guard let executable = paths.lazy.map({ URL(fileURLWithPath: $0).appendingPathComponent(tool) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationReason == .exit && process.terminationStatus == 0 ? data : nil
    }
}
