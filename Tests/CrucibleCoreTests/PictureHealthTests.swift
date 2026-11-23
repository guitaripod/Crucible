import Foundation
import Testing
@testable import CrucibleCore

struct PictureHealthTests {
    /// The frame a server whose decoder cannot handle VC-1 paints: one flat colour, luma at black and chroma far off neutral,
    /// measured from the broken transcoder's own output.
    private let deadFrame = PictureSample(luma: 16, blue: 72, red: 128, lumaSpread: 0, chromaSpread: 0)
    /// A frame of real content, measured from the same file decoded on the CPU.
    private let realFrame = PictureSample(luma: 80, blue: 132, red: 124, lumaSpread: 190, chromaSpread: 90)

    @Test func aRunOfDeadFramesTripsExactlyOnce() {
        var watchdog = PictureWatchdog()
        for _ in 1..<PictureWatchdog.samplesNeeded {
            let tripped = watchdog.observe(deadFrame)
            #expect(!tripped)
        }
        let tripped = watchdog.observe(deadFrame)
        #expect(tripped)
        let again = watchdog.observe(deadFrame)
        let onceMore = watchdog.observe(deadFrame)
        #expect(!again)
        #expect(!onceMore)
    }

    @Test func realContentNeverTrips() {
        var watchdog = PictureWatchdog()
        for _ in 0..<50 {
            let tripped = watchdog.observe(realFrame)
            #expect(!tripped)
        }
    }

    @Test func realContentBetweenDeadFramesBreaksTheRun() {
        var watchdog = PictureWatchdog()
        for _ in 1..<PictureWatchdog.samplesNeeded {
            let tripped = watchdog.observe(deadFrame)
            #expect(!tripped)
        }
        let parked = watchdog.observe(realFrame)
        #expect(!parked)
        for _ in 1..<PictureWatchdog.samplesNeeded {
            let tripped = watchdog.observe(deadFrame)
            #expect(!tripped)
        }
    }

    @Test func aFlatBlackFrameIsAFadeAndNotADeadPicture() {
        let black = PictureSample(luma: 16, blue: 128, red: 128, lumaSpread: 0, chromaSpread: 0)
        var watchdog = PictureWatchdog()
        for _ in 0..<50 {
            let tripped = watchdog.observe(black)
            #expect(!tripped)
        }
    }

    @Test func flatAndCastAreBothRequired() {
        let flatGrey = PictureSample(luma: 128, blue: 128, red: 128, lumaSpread: 1, chromaSpread: 1)
        let greenWithDetail = PictureSample(luma: 100, blue: 72, red: 128, lumaSpread: 60, chromaSpread: 8)
        #expect(PictureWatchdog.isFlat(flatGrey))
        #expect(!PictureWatchdog.isCast(flatGrey))
        #expect(!PictureWatchdog.isFlat(greenWithDetail))
        #expect(PictureWatchdog.isCast(greenWithDetail))
        #expect(PictureWatchdog.isFlat(deadFrame))
        #expect(PictureWatchdog.isCast(deadFrame))
    }

    @Test func onlyTheCodecsHardwareDecodingFailsOnAreWatched() {
        #expect(PictureTrouble.canBreak("vc1"))
        #expect(PictureTrouble.canBreak("VC1"))
        #expect(PictureTrouble.canBreak("mpeg2video"))
        #expect(PictureTrouble.canBreak("wmv2"))
        #expect(!PictureTrouble.canBreak("h264"))
        #expect(!PictureTrouble.canBreak("hevc"))
        #expect(!PictureTrouble.canBreak("av1"))
        #expect(!PictureTrouble.canBreak(nil))
    }

    @Test func theExplanationNamesTheCodecOnlyWhereHardwareDecodingFails() {
        let trouble = PictureTrouble(videoCodec: "vc1", container: "asf")
        #expect(trouble.explanation.contains("This file is"))
        #expect(DetailFormat.videoCodecLabel("vc1") == "VC-1")
        #expect(trouble.explanation.contains("In Plex, open Settings, Transcoder and turn off “Use hardware acceleration when available”, then play it again. Converting the file to H.264 also fixes it for good."))
        #expect(!trouble.title.isEmpty)
        #expect(trouble.logLine == "picture dead codec=vc1 container=asf")
        #expect(!PictureTrouble(videoCodec: "h264", container: "mp4").explanation.contains("This file is"))
        #expect(PictureTrouble(videoCodec: nil, container: nil).explanation.contains("Crucible is playing a stream your Plex server converted, and the conversion has no picture in it: every frame arrives as one flat colour, usually green."))
    }
}
