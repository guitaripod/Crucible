import Foundation
import Testing
@testable import CrucibleCore

struct StreamProfileTests {
    private let hdrPhone = PlaybackCapabilities(decodesHEVC: true, decodesAV1: false, showsHDR: true)

    @Test func hevcIsCopiedIntoFragmentedMP4WithSurroundSound() {
        let directives = StreamProfile.directives(for: hdrPhone)
        #expect(directives.first == "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=hevc,h264&audioCodec=eac3,ac3,aac&replace=true)")
        #expect(directives.contains("add-limitation(scope=videoAudioCodec&scopeName=*&type=upperBound&name=audio.channels&value=8&onlyTranscodes=true&replace=true)"))
        #expect(directives.last == "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)")
    }

    @Test func dualLayerDolbyVisionAndTwelveBitHEVCAreLeftToTheServer() {
        let directives = StreamProfile.directives(for: hdrPhone)
        #expect(directives.contains("add-limitation(scope=videoCodec&scopeName=hevc&type=notMatch&name=video.DOVIProfile&value=7)"))
        #expect(directives.contains("add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.bitDepth&value=10)"))
    }

    @Test func h264IsCopiedUpTo4K() {
        let directives = StreamProfile.directives(for: hdrPhone)
        #expect(directives.contains("add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.width&value=4096&replace=true)"))
        #expect(directives.contains("add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.height&value=2304&replace=true)"))
    }

    @Test func aScreenWithoutHDRHasPQVideoConvertedButKeepsHLG() {
        let sdrScreen = PlaybackCapabilities(decodesHEVC: true, decodesAV1: true, showsHDR: false)
        let directives = StreamProfile.directives(for: sdrScreen)
        #expect(directives.contains("add-limitation(scope=videoCodec&scopeName=hevc&type=notMatch&name=video.colorTrc&value=smpte2084)"))
        #expect(directives.contains("add-limitation(scope=videoCodec&scopeName=av1&type=notMatch&name=video.colorTrc&value=smpte2084)"))
        #expect(!directives.contains { $0.contains("scopeName=h264&type=notMatch") })
        #expect(!directives.contains { $0.contains("arib-std-b67") })
        #expect(!StreamProfile.directives(for: hdrPhone).contains { $0.contains("video.colorTrc") })
    }

    @Test func av1JoinsWhereTheChipDecodesIt() {
        let directives = StreamProfile.directives(for: PlaybackCapabilities(decodesHEVC: true, decodesAV1: true, showsHDR: true))
        #expect(directives.first?.contains("&videoCodec=hevc,av1,h264&") == true)
    }

    @Test func anAppleTVHDStaysWithH264At1080p() {
        let directives = StreamProfile.directives(for: PlaybackCapabilities(decodesHEVC: false, decodesAV1: false, showsHDR: false))
        #expect(directives.first?.contains("&videoCodec=h264&") == true)
        #expect(!directives.contains { $0.contains("scopeName=hevc") || $0.contains("video.width") })
    }

    @Test func theQueryValueEscapesTheSeparators() {
        let value = StreamProfile.queryValue(for: hdrPhone)
        #expect(!value.contains("+"))
        #expect(!value.contains("&"))
        #expect(value.removingPercentEncoding == StreamProfile.extra(for: hdrPhone))
    }
}
