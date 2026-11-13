import Foundation
import Testing
@testable import CrucibleCore

struct DynamicRangeTests {
    private func video(_ fields: [String: Any]) throws -> PlexStream {
        var fields = fields
        fields["streamType"] = 1
        return try JSONDecoder().decode(PlexStream.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func dolbyVisionIsNamedWithItsProfileAndBaseLayer() throws {
        let profile81 = try video(["DOVIPresent": true, "DOVIProfile": 8, "DOVIBLCompatID": 1, "colorTrc": "smpte2084", "displayTitle": "4K DoVi/HDR10"])
        #expect(DynamicRange(profile81) == .dolbyVision(profile: 8, compatibility: 1))
        #expect(DynamicRange(profile81).name == "Dolby Vision 8.1")
        let profile5 = try video(["DOVIPresent": true, "DOVIProfile": 5, "DOVIBLCompatID": 0])
        #expect(DynamicRange(profile5).name == "Dolby Vision 5")
        #expect(!DynamicRange(profile5).isDualLayerDolbyVision)
        let profile7 = try video(["DOVIPresent": "1", "DOVIProfile": "7", "DOVIBLCompatID": "6"])
        #expect(DynamicRange(profile7).name == "Dolby Vision 7")
        #expect(DynamicRange(profile7).isDualLayerDolbyVision)
    }

    @Test func theTransferFunctionTellsHDR10FromHLG() throws {
        #expect(try DynamicRange(video(["colorTrc": "smpte2084"])) == .hdr10)
        #expect(try DynamicRange(video(["colorTrc": "arib-std-b67"])) == .hlg)
        #expect(try DynamicRange(video(["colorTrc": "smpte2084", "HDR10PlusPresent": true])) == .hdr10Plus)
        #expect(try DynamicRange(video(["colorTrc": "bt709"])) == .sdr)
        #expect(DynamicRange(nil) == .sdr)
    }

    @Test func anOlderServersLabelStillCounts() throws {
        #expect(try DynamicRange(video(["displayTitle": "4K DoVi/HDR10"])) == .dolbyVision(profile: nil, compatibility: nil))
        #expect(try DynamicRange(video(["displayTitle": "4K DoVi/HDR10"])).name == "Dolby Vision")
        #expect(try DynamicRange(video(["displayTitle": "4K HDR10+"])) == .hdr10Plus)
        #expect(try DynamicRange(video(["displayTitle": "1080p HLG"])) == .hlg)
        #expect(try DynamicRange(video(["displayTitle": "4K HDR"])) == .hdr10)
        #expect(try DynamicRange(video(["displayTitle": "1080p (H.264)"])) == .sdr)
    }

    @Test func pictureFactsDecodeFromNumbersOrStrings() throws {
        let stream = try video(["bitDepth": "10", "frameRate": "23.976", "colorTrc": "smpte2084", "DOVIPresent": 1])
        #expect(stream.bitDepth == 10)
        #expect(stream.frameRate == 23.976)
        #expect(stream.doviPresent)
        let bare = try video([:])
        #expect(!bare.doviPresent && !bare.hdr10PlusPresent && bare.frameRate == nil)
        let odd = try video(["frameRate": ["not": "a number"], "colorTrc": 5])
        #expect(odd.frameRate == nil && odd.colorTrc == nil)
    }
}

struct StreamInfoDynamicRangeTests {
    private func media(_ video: String) throws -> PlexMedia {
        try JSONDecoder().decode(PlexMedia.self, from: Data(#"{"videoCodec": "hevc", "width": 3840, "height": 2160, "container": "mkv", "Part": [{"id": 1, "key": "/library/parts/1/file.mkv", "Stream": [\#(video)]}]}"#.utf8))
    }

    private func lines(_ media: PlexMedia, direct: Bool = false, decision: PlaybackDecision? = nil) -> [String: String] {
        let stream = ResolvedStream(
            url: URL(string: "http://pms.test/video/:/transcode/universal/start.m3u8")!,
            isDirectPlay: direct, sessionId: "s", subtitles: [], audioTracks: [], markers: [], media: media, decision: decision
        )
        let lines = StreamInfo.lines(stream: stream, route: .local, quality: .original, audioId: nil, subtitleId: nil)
        return Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0.value) })
    }

    @Test func aCopiedPictureKeepsItsRangeAndShowsItsFrameRate() throws {
        let dv = try media(#"{"id": 1, "streamType": 1, "DOVIPresent": true, "DOVIProfile": 8, "DOVIBLCompatID": 1, "colorTrc": "smpte2084", "frameRate": 23.976}"#)
        let copied = lines(dv, decision: PlaybackDecision(generalCode: 1001, generalText: nil, videoDecision: "copy", audioDecision: "copy", videoTransfer: "smpte2084"))
        #expect(copied["Dynamic Range"] == "Dolby Vision 8.1")
        #expect(copied["Video"] == "HEVC · 4K · 23.976 fps")
        #expect(lines(dv, direct: true)["Dynamic Range"] == "Dolby Vision 8.1")
    }

    @Test func aConvertedPictureSaysWhatItBecame() throws {
        let hdr10 = try media(#"{"id": 1, "streamType": 1, "colorTrc": "smpte2084", "frameRate": 24}"#)
        let toSDR = lines(hdr10, decision: PlaybackDecision(generalCode: 1001, generalText: nil, videoDecision: "transcode"))
        #expect(toSDR["Dynamic Range"] == "SDR, converted from HDR10")
        #expect(toSDR["Video"] == "HEVC · 4K · 24 fps")
        let keptHDR = lines(hdr10, decision: PlaybackDecision(generalCode: 1001, generalText: nil, videoDecision: "transcode", videoTransfer: "smpte2084"))
        #expect(keptHDR["Dynamic Range"] == "HDR10")
        let sdr = try media(#"{"id": 1, "streamType": 1}"#)
        #expect(lines(sdr, decision: PlaybackDecision(generalCode: 1001, generalText: nil, videoDecision: "transcode"))["Dynamic Range"] == "SDR")
    }

    @Test func theDecisionReadsTheTransferOfThePictureItSends() throws {
        let json = #"{"MediaContainer": {"generalDecisionCode": 1001, "Metadata": [{"Media": [{"Part": [{"Stream": [{"streamType": 1, "decision": "copy", "colorTrc": "smpte2084"}, {"streamType": 2, "decision": "copy"}]}]}]}]}}"#
        let decision = try #require(PlaybackDecision.parse(Data(json.utf8)))
        #expect(decision.videoDecision == "copy")
        #expect(decision.videoTransfer == "smpte2084")
    }
}
