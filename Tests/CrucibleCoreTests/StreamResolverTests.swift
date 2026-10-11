import Foundation
import Testing
@testable import CrucibleCore

@Suite(.serialized)
struct StreamResolverTests {
    private let base = URL(string: "http://192.168.1.5:32400/")!

    private func withQuality<T>(_ quality: Preferences.Quality, _ body: () -> T) -> T {
        let previous = Preferences.streamingQuality
        Preferences.streamingQuality = quality
        defer { Preferences.streamingQuality = previous }
        return body()
    }

    private func transcode(startSecs: Double? = nil, subtitles: String = "auto") -> String {
        let url = StreamResolver.transcodeURL(
            baseURL: base,
            token: "tok",
            ratingKey: "42",
            session: "sess",
            startSecs: startSecs,
            subtitlesMode: subtitles
        )
        return url?.absoluteString ?? ""
    }

    @Test func nativeContainersAndCodecsDirectPlay() {
        #expect(StreamResolver.isDirectPlayable(container: "mp4", videoCodec: "h264", audioCodec: "aac"))
        #expect(StreamResolver.isDirectPlayable(container: "mov", videoCodec: "hevc", audioCodec: "eac3"))
        #expect(StreamResolver.isDirectPlayable(container: "m4v", videoCodec: "H264", audioCodec: "FLAC"))
    }

    @Test func unsupportedContainerVideoOrAudioForcesTranscode() {
        #expect(!StreamResolver.isDirectPlayable(container: "mkv", videoCodec: "h264", audioCodec: "aac"))
        #expect(!StreamResolver.isDirectPlayable(container: "mp4", videoCodec: "vp9", audioCodec: "aac"))
        #expect(!StreamResolver.isDirectPlayable(container: "mp4", videoCodec: "h264", audioCodec: "dts"))
        #expect(!StreamResolver.isDirectPlayable(container: nil, videoCodec: "h264", audioCodec: "aac"))
        #expect(!StreamResolver.isDirectPlayable(container: "mp4", videoCodec: nil, audioCodec: "aac"))
        #expect(!StreamResolver.isDirectPlayable(container: "mp4", videoCodec: "h264", audioCodec: nil))
    }

    @Test func transcodeURLTargetsTheUniversalHlsEndpoint() {
        let url = withQuality(.original) { transcode() }
        #expect(url.hasPrefix("http://192.168.1.5:32400/video/:/transcode/universal/start.m3u8?path=/library/metadata/42"))
        #expect(url.contains("&protocol=hls"))
        #expect(url.contains("&session=sess"))
        #expect(url.contains("&subtitles=auto"))
        #expect(url.contains("&X-Plex-Token=tok"))
        #expect(url.contains("&X-Plex-Client-Identifier="))
        #expect(url.contains("&X-Plex-Platform=\(AppPlatform.plexName)"))
        #expect(url.hasSuffix("&X-Plex-Product=Crucible"))
    }

    @Test func transcodeURLAddsOffsetOnlyWhenResuming() {
        let fresh = withQuality(.original) { transcode() }
        #expect(!fresh.contains("offset="))
        let resumed = withQuality(.original) { transcode(startSecs: 90.7) }
        #expect(resumed.hasSuffix("&offset=90"))
    }

    @Test func transcodeURLCapsBitrateUnlessOriginalQuality() {
        let original = withQuality(.original) { transcode() }
        #expect(!original.contains("maxVideoBitrate"))
        let medium = withQuality(.medium) { transcode() }
        #expect(medium.hasSuffix("&maxVideoBitrate=8000&videoQuality=100"))
    }

    @Test func transcodeURLCarriesTheSubtitleMode() {
        let burned = withQuality(.original) { transcode(subtitles: "burn") }
        #expect(burned.contains("&subtitles=burn"))
    }
}
