import Foundation

/// Whether surround audio reaches a receiver or TV untouched (docs/LINUX.md §7.6, Linux): mpv sends the codecs listed in
/// `audio-spdif` as IEC 61937 bitstreams and decodes the rest to multichannel PCM.
package enum AudioPassthrough: Int, CaseIterable, Sendable {
    /// What the sound output is set to accept, its IEC958 codecs in PipeWire.
    case automatic = 0
    /// Every codec, which the output is then set to accept.
    case always = 1
    /// Crucible decodes everything.
    case never = 2

    package var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic", comment: "Audio passthrough choice: send what the sound output accepts")
        case .always: return String(localized: "Always", comment: "Audio passthrough choice: send every bitstream format")
        case .never: return String(localized: "Never")
        }
    }
}

extension Preferences {
    private static let audioPassthroughKey = "audio.passthrough"

    package static var audioPassthrough: AudioPassthrough {
        get { (UserDefaults.standard.object(forKey: audioPassthroughKey) as? Int).flatMap(AudioPassthrough.init(rawValue:)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: audioPassthroughKey) }
    }
}

/// A PipeWire sink as `pw-dump` describes it: its node, its name and the IEC958 codecs it is set to accept.
package struct PipeWireSink: Equatable, Sendable {
    package var id: Int
    package var name: String
    package var codecs: [String]

    package init(id: Int, name: String, codecs: [String]) {
        self.id = id
        self.name = name
        self.codecs = codecs
    }

    /// The default audio sink in `pw-dump`'s JSON: the node the default metadata names, with its `iec958Codecs`.
    package static func defaultSink(inDump data: Data) -> PipeWireSink? {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let defaults = objects.first {
            $0["type"] as? String == "PipeWire:Interface:Metadata" && (($0["props"] as? [String: Any])?["metadata.name"] as? String) == "default"
        }
        let entries = defaults?["metadata"] as? [[String: Any]] ?? []
        let named = ["default.audio.sink", "default.configured.audio.sink"].lazy.compactMap { key in
            entries.first { $0["key"] as? String == key }.flatMap { ($0["value"] as? [String: Any])?["name"] as? String }
        }.first
        guard let named else { return nil }
        for object in objects where object["type"] as? String == "PipeWire:Interface:Node" {
            guard let info = object["info"] as? [String: Any], let props = info["props"] as? [String: Any],
                  props["node.name"] as? String == named, let id = object["id"] as? Int else { continue }
            let params = (info["params"] as? [String: Any])?["Props"] as? [[String: Any]] ?? []
            let codecs = params.lazy.compactMap { $0["iec958Codecs"] as? [String] }.first ?? []
            return PipeWireSink(id: id, name: named, codecs: codecs)
        }
        return nil
    }
}

/// What to do before a play so the receiver gets bitstreams: mpv's `audio-spdif` codecs, the IEC958 codecs to set on the
/// sink again (PipeWire forgets them when the sink reconnects, PipeWire issue 3462) and the choice to remember for that.
package struct AudioPassthroughPlan: Equatable, Sendable {
    /// mpv's `audio-spdif` list, empty to decode everything.
    package var spdif: [String]
    /// The IEC958 codecs to set on the sink, nil when it already accepts what is sent.
    package var reapply: [String]?
    /// The sink's own choice of codecs, kept to restore it after PipeWire forgets.
    package var remember: [String]?

    /// PipeWire's codec names and mpv's for the bitstreams it can pass through, best first.
    private static let codecs: [(pipeWire: String, mpv: String)] = [
        ("TrueHD", "truehd"), ("DTS-HD", "dts-hd"), ("EAC3", "eac3"), ("DTS", "dts"), ("AC3", "ac3"),
    ]

    /// The plan for `setting` with `sink` as the output; `remembered` is the sink's last choice of codecs.
    package static func make(_ setting: AudioPassthrough, sink: PipeWireSink?, remembered: [String]?) -> AudioPassthroughPlan {
        guard let sink else { return AudioPassthroughPlan(spdif: [], reapply: nil, remember: nil) }
        let current = bitstreams(sink.codecs)
        let remember = current.isEmpty ? nil : sink.codecs
        switch setting {
        case .never:
            return AudioPassthroughPlan(spdif: [], reapply: nil, remember: remember)
        case .always:
            let every = codecs.map(\.pipeWire)
            let missing = every.filter { !sink.codecs.contains($0) }
            let wanted = ["PCM"] + every
            return AudioPassthroughPlan(spdif: codecs.map(\.mpv), reapply: missing.isEmpty ? nil : wanted, remember: remember)
        case .automatic:
            if !current.isEmpty { return AudioPassthroughPlan(spdif: mpvNames(current), reapply: nil, remember: remember) }
            let restored = bitstreams(remembered ?? [])
            guard !restored.isEmpty else { return AudioPassthroughPlan(spdif: [], reapply: nil, remember: nil) }
            return AudioPassthroughPlan(spdif: mpvNames(restored), reapply: ["PCM"] + restored, remember: nil)
        }
    }

    /// The pass-through codecs among PipeWire's names, in the order mpv prefers.
    private static func bitstreams(_ names: [String]) -> [String] {
        codecs.map(\.pipeWire).filter(names.contains)
    }

    private static func mpvNames(_ names: [String]) -> [String] {
        codecs.filter { names.contains($0.pipeWire) }.map(\.mpv)
    }
}
