import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import CrucibleCore

/// Checks against the real services, run by hand: `CRUCIBLE_LIVE_TOKEN=<plex token>` reads Plex's free channels and
/// their guide, `CRUCIBLE_LIVE_TS=<file>` cuts a captured transport stream into segments written to `<file>.hls/`, where
/// `ffprobe <file>.hls/live.m3u8` should read it back.
@Suite("Live TV against real services", .serialized)
struct LiveTVProbeTests {
    private static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["CRUCIBLE_LIVE_TOKEN"] != nil))
    func readsPlexFreeChannelsAndTheirGuide() async throws {
        let source = PlexFreeChannelSource(token: try #require(Self.environment["CRUCIBLE_LIVE_TOKEN"]))
        let channels = try await source.channels()
        #expect(channels.count > 20)
        #expect(channels.allSatisfy { if case .plexFree = $0.stream { true } else { false } })
        #expect(channels.contains { !$0.groups.isEmpty })
        let window = DateInterval(start: Date().addingTimeInterval(-1800), duration: 6 * 3600)
        let sample = Array(channels.prefix(4))
        let programs = try await source.programs(for: sample, in: window)
        #expect(programs.values.filter { !$0.isEmpty }.count >= 2)
        for (_, list) in programs {
            #expect(zip(list, list.dropFirst()).allSatisfy { $0.end <= $1.start })
        }
        let onNow = sample.compactMap { LiveGuideMath.nowAndNext(programs[$0.id] ?? [], at: Date()).now }
        #expect(!onNow.isEmpty)
        let plan = try await LivePlayback.plan(for: sample[0], token: Self.environment["CRUCIBLE_LIVE_TOKEN"]!, api: nil)
        #expect(plan.format == .hls)
        let (data, response) = try await HTTPSession.current.data(from: plan.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data.prefix(7), as: UTF8.self) == "#EXTM3U")
    }

    @Test(.enabled(if: environment["CRUCIBLE_LIVE_TS"] != nil))
    func cutsACapturedStream() throws {
        let path = try #require(Self.environment["CRUCIBLE_LIVE_TS"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var segmenter = TransportStreamSegmenter(targetDuration: 2)
        var window = LiveHLSWindow(capacity: 100)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 64 * 1024, data.count)
            for segment in segmenter.append(data.subdata(in: offset..<end)) { window.add(segment) }
            offset = end
        }
        #expect(segmenter.hasVideo)
        #expect(window.segments.count >= 2)
        let folder = URL(fileURLWithPath: path + ".hls", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for segment in window.segments { try segment.data.write(to: folder.appendingPathComponent("segment-\(segment.sequence).ts")) }
        try (window.playlist + "#EXT-X-ENDLIST\n").write(to: folder.appendingPathComponent("live.m3u8"), atomically: true, encoding: .utf8)
        for segment in window.segments { #expect(segment.duration > 0.5 && segment.duration < 8.1) }
    }
}
