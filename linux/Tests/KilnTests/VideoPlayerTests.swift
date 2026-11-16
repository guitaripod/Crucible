import Testing
@testable import Kiln

@Suite("Video player")
struct VideoPlayerTests {
    @Test func chromaGoesBilinearOnlyForPicturesShownAtHalfTheirSizeOrLess() {
        #expect(VideoPlayer.showsAtHalfOrLess(videoWidth: 3840, videoHeight: 2160, viewWidth: 1280, viewHeight: 800))
        #expect(VideoPlayer.showsAtHalfOrLess(videoWidth: 3840, videoHeight: 2160, viewWidth: 1920, viewHeight: 1080))
        #expect(!VideoPlayer.showsAtHalfOrLess(videoWidth: 1920, videoHeight: 1080, viewWidth: 1280, viewHeight: 800))
        #expect(!VideoPlayer.showsAtHalfOrLess(videoWidth: 640, videoHeight: 480, viewWidth: 1280, viewHeight: 800))
        #expect(VideoPlayer.showsAtHalfOrLess(videoWidth: 3840, videoHeight: 1608, viewWidth: 1280, viewHeight: 800),
                "a scope picture fits by its width")
        #expect(!VideoPlayer.showsAtHalfOrLess(videoWidth: 0, videoHeight: 0, viewWidth: 1280, viewHeight: 800))
    }
}
