import Foundation
import Testing
@testable import CrucibleCore

@Suite("Audio passthrough")
struct AudioPassthroughTests {
    /// The shape `pw-dump` prints: the default metadata, then nodes with their Props.
    private static let dump = Data("""
    [
      { "id": 30, "type": "PipeWire:Interface:Metadata", "props": { "metadata.name": "default" },
        "metadata": [ { "subject": 0, "key": "default.audio.sink", "type": "Spa:String:JSON",
                        "value": { "name": "alsa_output.pci-0000_01_00.1.hdmi-stereo" } } ] },
      { "id": 52, "type": "PipeWire:Interface:Node",
        "info": { "props": { "node.name": "alsa_output.usb-Focusrite.pro-output-0", "media.class": "Audio/Sink" },
                  "params": { "Props": [ { "volume": 1.0 } ] } } },
      { "id": 123, "type": "PipeWire:Interface:Node",
        "info": { "props": { "node.name": "alsa_output.pci-0000_01_00.1.hdmi-stereo", "media.class": "Audio/Sink" },
                  "params": { "Props": [ { "volume": 1.0 }, { "iec958Codecs": [ "PCM", "AC3", "EAC3", "TrueHD" ] } ] } } }
    ]
    """.utf8)

    @Test func theDefaultSinkComesWithItsCodecs() {
        let sink = PipeWireSink.defaultSink(inDump: Self.dump)
        #expect(sink == PipeWireSink(id: 123, name: "alsa_output.pci-0000_01_00.1.hdmi-stereo", codecs: ["PCM", "AC3", "EAC3", "TrueHD"]))
        #expect(PipeWireSink.defaultSink(inDump: Data("not json".utf8)) == nil)
        #expect(PipeWireSink.defaultSink(inDump: Data("[]".utf8)) == nil)
    }

    @Test func automaticSendsWhatTheSinkAcceptsAndRemembersIt() {
        let sink = PipeWireSink(id: 123, name: "hdmi", codecs: ["PCM", "AC3", "EAC3", "TrueHD"])
        let plan = AudioPassthroughPlan.make(.automatic, sink: sink, remembered: nil)
        #expect(plan.spdif == ["truehd", "eac3", "ac3"])
        #expect(plan.reapply == nil)
        #expect(plan.remember == ["PCM", "AC3", "EAC3", "TrueHD"])
    }

    @Test func automaticRestoresCodecsPipeWireForgot() {
        let forgot = PipeWireSink(id: 123, name: "hdmi", codecs: ["PCM"])
        let plan = AudioPassthroughPlan.make(.automatic, sink: forgot, remembered: ["PCM", "DTS", "AC3"])
        #expect(plan.spdif == ["dts", "ac3"])
        #expect(plan.reapply == ["PCM", "DTS", "AC3"])
        #expect(plan.remember == nil, "a forgotten state is never remembered over the choice")
        #expect(AudioPassthroughPlan.make(.automatic, sink: forgot, remembered: nil).spdif.isEmpty, "PCM alone is decoded")
    }

    @Test func alwaysSendsEveryCodecAndOpensTheSinkToThem() {
        let plan = AudioPassthroughPlan.make(.always, sink: PipeWireSink(id: 7, name: "hdmi", codecs: ["PCM", "AC3"]), remembered: nil)
        #expect(plan.spdif == ["truehd", "dts-hd", "eac3", "dts", "ac3"])
        #expect(plan.reapply == ["PCM", "TrueHD", "DTS-HD", "EAC3", "DTS", "AC3"])
        let open = PipeWireSink(id: 7, name: "hdmi", codecs: ["PCM", "TrueHD", "DTS-HD", "EAC3", "DTS", "AC3"])
        #expect(AudioPassthroughPlan.make(.always, sink: open, remembered: nil).reapply == nil)
    }

    @Test func neverDecodesAndNoSinkMeansNothingToSend() {
        let sink = PipeWireSink(id: 123, name: "hdmi", codecs: ["PCM", "AC3"])
        #expect(AudioPassthroughPlan.make(.never, sink: sink, remembered: nil) == AudioPassthroughPlan(spdif: [], reapply: nil, remember: ["PCM", "AC3"]))
        #expect(AudioPassthroughPlan.make(.always, sink: nil, remembered: ["AC3"]).spdif.isEmpty)
    }

    @Test @MainActor func theSettingIsLinuxOnlyAndChoosesBetweenThree() {
        #expect(PreferenceSetting.audioPassthrough.choices.map(\.title) == ["Automatic", "Always", "Never"])
        #expect(SettingsCatalog.preferences(in: .playback, on: .linux).contains(.audioPassthrough))
        #expect(!SettingsCatalog.preferences(in: .playback, on: .tv).contains(.audioPassthrough))
        #expect(!SettingsCatalog.preferences(in: .playback, on: .phone).contains(.audioPassthrough))
    }
}
