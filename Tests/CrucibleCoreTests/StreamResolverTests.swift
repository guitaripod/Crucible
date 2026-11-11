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

    @Test func transcodeURLAsksForTextSubtitlesAsAWebVTTRendition() throws {
        let url = withQuality(.original) { transcode(subtitles: "none") }
        #expect(url.contains("&subtitles=none"))
        let extra = try #require(URLComponents(string: url)?.queryItems?.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
        #expect(extra == "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)")
    }

    @Test func eachSubtitleDeliveryAsksTheTranscoderForItsOwnMode() {
        #expect(SubtitleDelivery.none.transcodeParameter == "none")
        #expect(SubtitleDelivery.track.transcodeParameter == "auto")
        #expect(SubtitleDelivery.burned.transcodeParameter == "burn")
    }

    @Test func onlyTextTracksInsideTheFilePlayFromTheFile() {
        #expect(StreamResolver.isFileTrack(subtitle(1, codec: "mov_text")))
        #expect(StreamResolver.isFileTrack(subtitle(2, codec: "tx3g")))
        #expect(!StreamResolver.isFileTrack(subtitle(3, codec: "srt")))
        #expect(!StreamResolver.isFileTrack(subtitle(4, codec: "mov_text", key: "/library/streams/4")))
        #expect(!StreamResolver.isFileTrack(subtitle(5, codec: "hdmv_pgs_subtitle")))
    }

    @Test func alwaysOnCaptionsPickAFullTextSubtitleInTheDevicesLanguage() {
        let streams = [
            subtitle(1, codec: "hdmv_pgs_subtitle", language: "eng"),
            subtitle(2, codec: "srt", language: "eng", forced: true),
            subtitle(3, codec: "srt", language: "fin"),
            subtitle(4, codec: "srt", language: "eng"),
        ]
        #expect(StreamResolver.captionSubtitle(in: "en-US", among: streams)?.id == 4)
        #expect(StreamResolver.captionSubtitle(in: "fi", among: streams)?.id == 3)
        #expect(StreamResolver.captionSubtitle(in: "ja-JP", among: streams) == nil)
    }

    @Test func norwegianAndIcelandicViewersFindTheirTracks() {
        let streams = [
            subtitle(1, codec: "srt", language: "eng"),
            subtitle(2, codec: "srt", language: "nor"),
            subtitle(3, codec: "srt", language: "ice"),
            subtitle(4, codec: "srt", language: "swe"),
        ]
        #expect(StreamResolver.captionSubtitle(in: "nb-NO", among: streams)?.id == 2)
        #expect(StreamResolver.captionSubtitle(in: "no", among: streams)?.id == 2)
        #expect(StreamResolver.captionSubtitle(in: "is-IS", among: streams)?.id == 3)
        #expect(StreamResolver.captionSubtitle(in: "sv-SE", among: streams)?.id == 4)
        #expect(StreamResolver.captionSubtitle(in: "da-DK", among: streams) == nil)
    }

    private func subtitle(_ id: Int, codec: String, key: String? = nil, language: String = "eng", forced: Bool = false) -> PlexStream {
        var fields: [String: Any] = ["id": id, "streamType": 3, "codec": codec, "languageCode": language, "forced": forced]
        if let key { fields["key"] = key }
        return try! JSONDecoder().decode(PlexStream.self, from: JSONSerialization.data(withJSONObject: fields))
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
