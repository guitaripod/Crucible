import Testing
@testable import CrucibleCore

@Suite("Match Content")
struct MatchContentTests {
    private let tv = [144000, 120000, 119880, 100000, 60000, 59940, 50000].map { DisplayMode(width: 3840, height: 2160, refreshMilliHertz: $0) }
        + [DisplayMode(width: 1920, height: 1080, refreshMilliHertz: 143856)]
    private var desk: DisplayMode { DisplayMode(width: 3840, height: 2160, refreshMilliHertz: 144000) }

    private func plan(_ rate: Double?, hdr: Bool = false, capable: Bool = true, on: Bool = false, current: DisplayMode? = nil) -> MatchContentPlan {
        MatchContentPlan.make(frameRate: rate, isHDR: hdr, current: current ?? desk, modes: tv, hdrCapable: capable, hdrOn: on)
    }

    @Test func filmAndNTSCGoTo11988() {
        #expect(plan(23.976).refreshMilliHertz == 119880)
        #expect(plan(24000.0 / 1001).refreshMilliHertz == 119880)
        #expect(plan(29.97).refreshMilliHertz == 119880)
        #expect(plan(59.94).refreshMilliHertz == 119880)
    }

    @Test func palGoesTo100AndTrue24StaysOn144() {
        #expect(plan(25).refreshMilliHertz == 100000)
        #expect(plan(50).refreshMilliHertz == 100000)
        #expect(plan(24).refreshMilliHertz == nil, "144 Hz shows 24 fps six times a frame")
        #expect(plan(48).refreshMilliHertz == nil)
        #expect(plan(60).refreshMilliHertz == 120000)
    }

    @Test func onlyModesAtTheCurrentSizeCountAndMissingModesKeepTheScreen() {
        #expect(plan(23.976).refreshMilliHertz != 143856, "a mode at another size is never chosen")
        let sixty = DisplayMode(width: 3840, height: 2160, refreshMilliHertz: 60000)
        let only = MatchContentPlan.make(frameRate: 25, isHDR: false, current: sixty, modes: [sixty], hdrCapable: false, hdrOn: false)
        #expect(only.changesNothing)
        #expect(plan(nil).refreshMilliHertz == nil)
    }

    @Test func hdrTurnsOnForHDRTitlesOnScreensThatShowIt() {
        #expect(plan(24, hdr: true).hdr == true)
        #expect(plan(24, hdr: true, capable: false).hdr == nil)
        #expect(plan(24, hdr: true, on: true).hdr == nil, "already on")
        #expect(plan(24, hdr: false, on: true).hdr == nil, "an SDR title leaves HDR as the viewer set it")
    }

    @Test func aScreenWithVariableRefreshKeepsItsModeAndOnlyTurnsOnHDR() {
        let fast = DisplayMode(width: 3840, height: 2160, refreshMilliHertz: 165_000)
        let film = DisplayMode(width: 3840, height: 2160, refreshMilliHertz: 119_880)
        let sdr = MatchContentPlan.make(frameRate: 23.976, isHDR: false, current: fast, modes: [fast, film], hdrCapable: true, hdrOn: false, adaptiveSync: true)
        #expect(sdr.changesNothing)
        let hdr = MatchContentPlan.make(frameRate: 23.976, isHDR: true, current: fast, modes: [fast, film], hdrCapable: true, hdrOn: false, adaptiveSync: true)
        #expect(hdr.refreshMilliHertz == nil && hdr.hdr == true)
        let fixed = MatchContentPlan.make(frameRate: 23.976, isHDR: false, current: fast, modes: [fast, film], hdrCapable: true, hdrOn: false)
        #expect(fixed.refreshMilliHertz == 119_880)
    }
}
