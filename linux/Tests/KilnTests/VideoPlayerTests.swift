import Foundation
import Testing
@testable import Kiln

@Suite("Video player")
struct VideoPlayerTests {
    @Test func onlyThePlayheadAndTheBufferCountAsProgress() {
        var state = VideoPlayer.State()
        state.isPaused = false
        var moved = state
        moved.position = 12.5
        moved.cachedSeconds = 30
        #expect(moved.onlyProgressDiffers(from: state))
        #expect(!state.onlyProgressDiffers(from: state), "no change is no report")
        var paused = moved
        paused.isPaused = true
        #expect(!paused.onlyProgressDiffers(from: state), "a pause reports at once, with the playhead")
        var resized = state
        resized.videoWidth = 3840
        #expect(!resized.onlyProgressDiffers(from: state))
    }

    @Test func chromaGoesBilinearOnlyForPicturesShownAtHalfTheirSizeOrLess() {
        #expect(VideoPlayer.showsAtHalfOrLess(videoWidth: 3840, videoHeight: 2160, viewWidth: 1280, viewHeight: 800))
        #expect(VideoPlayer.showsAtHalfOrLess(videoWidth: 3840, videoHeight: 2160, viewWidth: 1920, viewHeight: 1080))
        #expect(!VideoPlayer.showsAtHalfOrLess(videoWidth: 1920, videoHeight: 1080, viewWidth: 1280, viewHeight: 800))
        #expect(!VideoPlayer.showsAtHalfOrLess(videoWidth: 640, videoHeight: 480, viewWidth: 1280, viewHeight: 800))
        #expect(VideoPlayer.showsAtHalfOrLess(videoWidth: 3840, videoHeight: 1608, viewWidth: 1280, viewHeight: 800),
                "a scope picture fits by its width")
        #expect(!VideoPlayer.showsAtHalfOrLess(videoWidth: 0, videoHeight: 0, viewWidth: 1280, viewHeight: 800))
    }

    /// Volume Boost's gain runs ahead of its limiter, so a quiet passage comes out amplified on mpv's cubic curve and a loud
    /// one held at the limiter's ceiling rather than pushed past full scale; and the gain lives in the filter list, so the
    /// filters a seek rebuilds keep it. Played through mpv's PCM writer, as fast as it decodes.
    @MainActor @Test func volumeBoostAmplifiesAheadOfItsLimiterAndKeepsItsGainThroughASeek() throws {
        let check = try PCMCheck()
        try FloatWAV.write([FloatWAV.tone(amplitudes: [0.1, 0.5]), FloatWAV.tone(amplitudes: [0.1, 0.5])], to: check.input)
        var ends = 0
        check.player.onEvent = { if case .ended = $0 { ends += 1 } }
        check.player.maximumVolume = 200
        check.player.load(check.input)
        try check.run { ends == 1 }
        check.player.setVolume(150)
        #expect(check.player.state.volume == 150)
        check.player.seek(to: 0)
        check.player.setPaused(false)
        try check.run { ends == 2 }
        check.player.maximumVolume = 100
        #expect(check.player.state.volume == 100, "turning the boost off brings the volume back to 100%")
        #expect(check.filters { $0.isEmpty } == "", "and takes its gain and limiter away")
        let played = try check.finish()

        #expect(played.channels == 2)
        let rate = FloatWAV.rate
        func peak(pass: Int, second: Int) -> Float { played.peak(from: (pass * 2 + second) * rate + rate / 5, to: (pass * 2 + second) * rate + rate * 4 / 5) }
        #expect(played.frames >= 4 * rate - rate / 10)
        #expect(abs(peak(pass: 0, second: 0) - 0.1) < 0.005, "100% plays the file as it is")
        #expect(abs(peak(pass: 0, second: 1) - 0.5) < 0.01, "a peak under the ceiling passes the limiter untouched")
        #expect(abs(peak(pass: 1, second: 0) - 0.3375) < 0.01, "150% is 1.5 cubed, and the seek kept it")
        #expect(peak(pass: 1, second: 1) <= Float(VideoPlayer.limiterCeiling) + 0.001, "0.5 at 150% would be 1.69: the limiter holds it")
        #expect(peak(pass: 1, second: 1) > Float(VideoPlayer.limiterCeiling) - 0.05)
    }

    /// A boosted 5.1 track for a stereo output is mixed down ahead of the limiter, so the channels the output's own downmix
    /// would have added up past full scale are held under the ceiling as well; a 5.1 output keeps all six.
    @MainActor @Test func volumeBoostMixesSurroundDownForAStereoOutputAheadOfItsLimiter() throws {
        let surround = (0..<6).map { FloatWAV.tone(amplitudes: [0.5], hertz: 300 + 200 * Float($0)) }
        for (outputChannels, expected) in [(2, 2), (6, 6)] {
            let check = try PCMCheck()
            try FloatWAV.write(surround, to: check.input)
            var ended = false
            check.player.onEvent = { if case .ended = $0 { ended = true } }
            check.player.outputChannels = outputChannels
            check.player.maximumVolume = 200
            check.player.setVolume(200)
            check.player.load(check.input)
            try check.run { ended }
            let played = try check.finish()
            #expect(played.channels == expected)
            let peak = played.peak(from: FloatWAV.rate / 5, to: FloatWAV.rate * 4 / 5)
            #expect(peak <= Float(VideoPlayer.limiterCeiling) + 0.001)
            #expect(peak > Float(VideoPlayer.limiterCeiling) - 0.05)
        }
    }

    /// A volume change past 100% moves the running filter's gain without rebuilding mpv's filters, so the list keeps the
    /// gain it had until the volume rests, then catches up; a seek, which rebuilds the filters from the list, sends the
    /// newest gain into it first.
    @MainActor @Test func volumeBoostMovesTheRunningGainAndWritesTheListOnceTheVolumeRests() async throws {
        let check = try PCMCheck()
        let tone = FloatWAV.tone(amplitudes: [0.1, 0.1, 0.1])
        try FloatWAV.write([tone, tone], to: check.input)
        var loaded = false
        check.player.onEvent = { if case .loaded = $0 { loaded = true } }
        check.player.maximumVolume = 200
        check.player.setPaused(true)
        check.player.load(check.input)
        try check.run { loaded }
        check.player.setVolume(150)
        #expect(check.player.get("af")?.contains("volume=1.0000") == true, "the list waits for the volume to rest")
        try await Task.sleep(for: .milliseconds(700))
        #expect(check.filters { $0.contains("volume=3.3750") } != nil, "then catches up")
        check.player.setVolume(200)
        check.player.seek(to: 0.5)
        #expect(check.filters { $0.contains("volume=8.0000") } != nil, "a seek sends the newest gain first")
        _ = try check.finish()
    }
}

/// A player writing what it plays to a float WAV file through mpv's PCM output, and the file it plays, in a folder of
/// their own that goes with the check.
@MainActor
private final class PCMCheck {
    let folder: URL
    let loop: EventLoop
    let player: VideoPlayer
    var input: URL { folder.appendingPathComponent("input.wav") }

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("KILN_AO", "pcm", 1)
        setenv("KILN_MPV_OPTIONS", "ao-pcm-file=\(folder.appendingPathComponent("played.wav").path);audio-format=float", 1)
        defer {
            unsetenv("KILN_AO")
            unsetenv("KILN_MPV_OPTIONS")
        }
        let loop = EventLoop()
        player = try VideoPlayer(gpu: TestGPU.shared, loop: loop)
        self.loop = loop
        self.folder = folder
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Turns the loop until `done`, failing after ten seconds.
    func run(until done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        loop.run(timeoutMilliseconds: 20) { done() || Date() > deadline }
        try #require(done())
    }

    /// mpv's filter list once it satisfies `wanted`, read for up to two seconds without letting this actor's timers run, so
    /// only what has already been sent can satisfy it; nil when it never does.
    func filters(_ wanted: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let list = player.get("af"), wanted(list) { return list }
            usleep(5000)
        }
        return nil
    }

    /// Shuts the player down, which completes the file, and reads what it played.
    func finish() throws -> FloatWAV {
        player.shutDown()
        return try FloatWAV(contentsOf: folder.appendingPathComponent("played.wav"))
    }
}

/// A 48 kHz float WAV file's samples, interleaved.
private struct FloatWAV {
    static let rate = 48000
    var channels: Int
    var samples: [Float]

    var frames: Int { samples.count / max(channels, 1) }

    /// The loudest sample in any channel between two frames.
    func peak(from start: Int, to end: Int) -> Float {
        samples[(start * channels)..<(min(end, frames) * channels)].map(abs).max() ?? 0
    }

    /// A tone, a second at each amplitude in turn.
    static func tone(amplitudes: [Float], hertz: Float = 440) -> [Float] {
        amplitudes.flatMap { amplitude in (0..<rate).map { amplitude * sin(2 * .pi * hertz * Float($0) / Float(rate)) } }
    }

    /// Writes one array of samples per channel, all as long; six are 5.1 by WAV's default order.
    static func write(_ channels: [[Float]], to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let frames = channels.map(\.count).min() ?? 0
        let bytes = frames * channels.count * 4
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(3))
        append(UInt16(channels.count))
        append(UInt32(rate))
        append(UInt32(rate * channels.count * 4))
        append(UInt16(channels.count * 4))
        append(UInt16(32))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(bytes))
        for frame in 0..<frames {
            for channel in channels { append(channel[frame].bitPattern) }
        }
        try data.write(to: url)
    }

    /// Reads `url`, taking the data to the file's end when the header left its size open.
    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        func word(_ at: Int, _ bytes: Int = 4) -> UInt32 {
            data[at..<(at + bytes)].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        var channels: Int?
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(word(offset + 4))
            if id == "fmt " { channels = Int(word(offset + 10, 2)) }
            if id == "data", let channels {
                let start = offset + 8
                let end = size == 0 || start + size > data.count ? data.count : start + size
                self.channels = channels
                samples = stride(from: start, to: end - 3, by: 4).map { Float(bitPattern: word($0)) }
                return
            }
            offset += 8 + size + size % 2
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
