import AVFoundation
import VideoToolbox

/// What this device's player can take as the file carries it, which decides what the server may copy into a stream rather
/// than convert.
package struct PlaybackCapabilities: Sendable, Equatable {
    /// Hardware HEVC decoding: every iPhone and iPad the app runs on, every Apple TV 4K; not the Apple TV HD, whose
    /// 1080p chip is also why 4K is only asked for alongside it.
    package let decodesHEVC: Bool
    /// Hardware AV1 decoding, from the A17 Pro and M3 on.
    package let decodesAV1: Bool
    /// Whether the screen shows HDR. The player refuses a stream whose only picture is PQ when it does not, so PQ video is then
    /// left to the server to convert; HLG stays, since it reads as SDR on any screen.
    package let showsHDR: Bool

    package init(decodesHEVC: Bool, decodesAV1: Bool, showsHDR: Bool) {
        self.decodesHEVC = decodesHEVC
        self.decodesAV1 = decodesAV1
        self.showsHDR = showsHDR
    }

    package static var current: PlaybackCapabilities {
        #if DEBUG
        if let forced = forcedForTesting { return forced }
        #endif
        return PlaybackCapabilities(
            decodesHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            decodesAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            showsHDR: AVPlayer.eligibleForHDRPlayback
        )
    }

    #if DEBUG
    /// `CRUCIBLE_CAPABILITIES=hevc,av1,hdr` (any of the three) stands in for the chip and the screen, so a simulator, which
    /// decodes in software and shows no HDR, takes the paths a device does.
    private static var forcedForTesting: PlaybackCapabilities? {
        guard let listed = ProcessInfo.processInfo.environment["CRUCIBLE_CAPABILITIES"] else { return nil }
        let names = Set(listed.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return PlaybackCapabilities(decodesHEVC: names.contains("hevc"), decodesAV1: names.contains("av1"), showsHDR: names.contains("hdr"))
    }
    #endif
}

/// The `X-Plex-Client-Profile-Extra` a transcoder stream asks for. Plex's own iOS and tvOS profiles only take 8-bit H.264 up
/// to 1080p in MPEG-TS, and stereo MP3 on iOS, so without this every MKV loses its HDR, its resolution and its surround sound to
/// a conversion. With it the server copies HEVC (HDR10, HDR10+, HLG and Dolby Vision 5 and 8 intact), AV1 where the chip
/// decodes it, and 4K H.264 into fragmented MP4 segments, the only kind Apple's player takes HEVC and AV1 in, and copies
/// E-AC-3 (Atmos included) and AC-3 or converts to them with every channel kept.
package enum StreamProfile {
    /// Asks the transcoder for a text subtitle as a WebVTT rendition of the HLS stream instead of burning it into the picture,
    /// so the player shows it as a real subtitle track: the system controls, Siri and the viewer's caption style all reach it.
    static let webVTTSubtitles = "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)"

    /// The directives joined the way the server reads them, one `+` between each.
    package static func extra(for capabilities: PlaybackCapabilities) -> String {
        directives(for: capabilities).joined(separator: "+")
    }

    /// `extra(for:)` escaped for a query string, its `+` separators included.
    package static func queryValue(for capabilities: PlaybackCapabilities) -> String {
        extra(for: capabilities).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    static func directives(for capabilities: PlaybackCapabilities) -> [String] {
        let codecs = videoCodecs(capabilities)
        var directives = [
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4"
                + "&videoCodec=\(codecs.joined(separator: ","))&audioCodec=eac3,ac3,aac&replace=true)",
        ]
        if capabilities.decodesHEVC {
            directives += [
                limitation("hevc", .upperBound, "video.bitDepth", "10"),
                limitation("hevc", .notMatch, "video.DOVIProfile", "7"),
                limitation("h264", .upperBound, "video.width", "4096", replacing: true),
                limitation("h264", .upperBound, "video.height", "2304", replacing: true),
            ]
        }
        if !capabilities.showsHDR {
            directives += codecs.filter { $0 != "h264" }.map { limitation($0, .notMatch, "video.colorTrc", "smpte2084") }
        }
        directives.append(
            "add-limitation(scope=videoAudioCodec&scopeName=*&type=upperBound&name=audio.channels&value=8&onlyTranscodes=true&replace=true)"
        )
        directives.append(webVTTSubtitles)
        return directives
    }

    /// HEVC first, so a server set to encode HEVC keeps 10-bit when it has to convert; H.264 last, which every server encodes.
    private static func videoCodecs(_ capabilities: PlaybackCapabilities) -> [String] {
        var codecs: [String] = []
        if capabilities.decodesHEVC { codecs.append("hevc") }
        if capabilities.decodesAV1 { codecs.append("av1") }
        codecs.append("h264")
        return codecs
    }

    private enum Bound: String {
        case upperBound
        case notMatch
    }

    private static func limitation(_ codec: String, _ bound: Bound, _ name: String, _ value: String, replacing: Bool = false) -> String {
        "add-limitation(scope=videoCodec&scopeName=\(codec)&type=\(bound.rawValue)&name=\(name)&value=\(value)\(replacing ? "&replace=true" : ""))"
    }
}
