import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// Stream Info's live half: what the player is doing with the title second by second, read from mpv (the picture it
/// decodes, the decoder, the bitrate arriving, the sound it sends, how far ahead it has buffered, what it dropped) and,
/// while the server converts, how fast the server keeps up. It refreshes every second while the info panel is open.
extension PlayerScreen {
    /// Starts refreshing the panel's live lines every second, and the server's side of a conversion every few.
    func startLiveStreamInfo() {
        infoTicker?.cancel()
        bitrateHistory = []
        infoTicker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, self.infoPanel != nil else { return }
                self.sampleLiveStreamInfo()
                if tick % 3 == 0 { await self.refreshServerTranscode() }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopLiveStreamInfo() {
        infoTicker?.cancel()
        infoTicker = nil
        serverTranscode = nil
    }

    /// Takes one sample of the bitrate for the graph and redraws the panel.
    private func sampleLiveStreamInfo() {
        guard let player else { return }
        let bits = [player.get("video-bitrate"), player.get("audio-bitrate")].compactMap { $0.flatMap(Double.init) }.reduce(0, +)
        bitrateHistory.append(bits)
        if bitrateHistory.count > 60 { bitrateHistory.removeFirst(bitrateHistory.count - 60) }
        infoPanel?.update(infoContent)
    }

    /// The server's own session for this stream, when it converts it and lets this account see its sessions.
    private func refreshServerTranscode() async {
        guard let stream, !stream.isDirectPlay, case .plex(let api, _, _) = source else {
            serverTranscode = nil
            return
        }
        let sessions = (try? await ServerActivity.sessions(api: api)) ?? []
        serverTranscode = sessions.compactMap(\.transcodeSession).first { $0.key?.contains(stream.sessionId) == true }
    }

    /// What the player does with the picture and sound now, one line each.
    var livePlaybackLines: [StreamInfoLine] {
        guard let player else { return [] }
        var lines: [StreamInfoLine] = []
        func number(_ property: String) -> Double? { player.get(property).flatMap(Double.init) }
        if let width = number("video-params/w"), let height = number("video-params/h"), width > 0 {
            var parts = ["\(Int(width)) × \(Int(height))"]
            if let codec = player.get("video-format"), !codec.isEmpty { parts.append(codec.uppercased()) }
            if let format = player.get("video-params/pixelformat") { parts.append(Self.bitDepth(of: format)) }
            if let fps = number("estimated-vf-fps") ?? number("container-fps"), fps > 0, let rate = StreamInfo.frameRate(fps) { parts.append(rate) }
            lines.append(StreamInfoLine(label: String(localized: "Picture"), value: parts.joined(separator: " · ")))
        }
        if let gamma = player.get("video-params/gamma"), let primaries = player.get("video-params/primaries") {
            var value = "\(Self.transferName(gamma)) · \(primaries.uppercased())"
            if let peak = appliedDisplayPeak { value += " → \(Int(peak)) cd/m²" }
            lines.append(StreamInfoLine(label: String(localized: "Dynamic Range", comment: "Stream Info label for HDR10, Dolby Vision, HLG or SDR"), value: value))
        }
        let decoder = player.get("hwdec-current").flatMap { $0.isEmpty || $0 == "no" ? nil : Self.decoderName($0) }
        lines.append(StreamInfoLine(label: String(localized: "Decoder", comment: "Stream Info label: how the picture is decoded"),
                                    value: decoder.map { String(localized: "Hardware (\($0))", comment: "Stream Info: decoded by the graphics card, with the API") }
                                        ?? String(localized: "Software (CPU)", comment: "Stream Info: decoded by the processor")))
        if let codec = player.get("audio-codec-name") {
            var value = codec.uppercased()
            if let channels = number("audio-params/channel-count") { value += " · \(Int(channels)) ch" }
            if let format = player.get("audio-out-params/format"), format.hasPrefix("spdif") {
                value += " · " + String(localized: "passed through", comment: "Stream Info: the sound goes to the receiver undecoded")
            } else if let rate = number("audio-out-params/samplerate"), let out = number("audio-out-params/channel-count") {
                value += " → PCM \(Int(out)) ch · \(String(format: "%g", locale: Formatters.interfaceLocale, rate / 1000)) kHz"
            }
            lines.append(StreamInfoLine(label: String(localized: "Audio Output", comment: "Stream Info label: the sound the player sends"), value: value))
        }
        if let sync = number("avsync") {
            lines.append(StreamInfoLine(label: String(localized: "A/V Sync", comment: "Stream Info label: how far sound and picture are apart"),
                                        value: String(format: "%+.0f ms", sync * 1000)))
        }
        let dropped = Int(number("frame-drop-count") ?? 0) + Int(number("decoder-frame-drop-count") ?? 0)
        lines.append(StreamInfoLine(label: String(localized: "Dropped Frames", comment: "Stream Info label"), value: "\(dropped)"))
        return lines
    }

    /// How the title reaches the player now: the bitrate arriving, how far ahead it is buffered, how fast it downloads
    /// and, while the server converts it, how fast the server keeps up.
    var liveDeliveryLines: [StreamInfoLine] {
        guard let player else { return [] }
        var lines: [StreamInfoLine] = []
        func number(_ property: String) -> Double? { player.get(property).flatMap(Double.init) }
        if let bits = bitrateHistory.last, bits > 0 {
            let peak = bitrateHistory.max() ?? bits
            lines.append(StreamInfoLine(label: String(localized: "Bitrate", comment: "Stream Info label"),
                                        value: String(localized: "\(Self.megabits(bits)) Mbps, peak \(Self.megabits(peak))",
                                                      comment: "Stream Info: the bitrate arriving now and the highest in the last minute")))
        }
        if let buffered = number("demuxer-cache-duration") {
            lines.append(StreamInfoLine(label: String(localized: "Buffered", comment: "Stream Info label: how far ahead the player has the title"),
                                        value: String(format: "%.1f s", locale: Formatters.interfaceLocale, buffered)))
        }
        if let stream, !stream.url.isFileURL, let speed = number("cache-speed"), speed > 0 {
            lines.append(StreamInfoLine(label: String(localized: "Download Speed", comment: "Stream Info label"),
                                        value: String(localized: "\(Self.megabits(speed * 8)) Mbps")))
        }
        if let session = serverTranscode {
            var value = session.speed.map { String(format: "%.1f×", locale: Formatters.interfaceLocale, $0) } ?? "–"
            let hardware = [session.transcodeHwDecoding, session.transcodeHwEncoding].compactMap { $0 }.filter { !$0.isEmpty }
            if !hardware.isEmpty { value += " · " + hardware.map { $0.uppercased() }.joined(separator: " → ") }
            if session.throttled == true { value += " · " + String(localized: "far enough ahead", comment: "Stream Info: the server paused converting because it is ahead") }
            lines.append(StreamInfoLine(label: String(localized: "Server Converting", comment: "Stream Info label: how fast the server converts the title"), value: value))
        }
        return lines
    }

    /// "18.4" for 18,400,000 bits a second.
    private static func megabits(_ bits: Double) -> String {
        String(format: "%.1f", locale: Formatters.interfaceLocale, bits / 1_000_000)
    }

    /// "10-bit" for yuv420p10 and p010, "8-bit" otherwise.
    private static func bitDepth(of format: String) -> String {
        format.contains("10") || format.contains("p010") ? "10-bit" : format.contains("12") ? "12-bit" : "8-bit"
    }

    /// The decoding API without mpv's copy-back suffix: "NVDEC" for nvdec-copy, "VAAPI" for vaapi.
    private static func decoderName(_ hwdec: String) -> String {
        (hwdec.hasSuffix("-copy") ? String(hwdec.dropLast("-copy".count)) : hwdec).uppercased()
    }

    /// mpv's transfer names as people know them.
    private static func transferName(_ gamma: String) -> String {
        switch gamma {
        case "pq": "PQ (HDR10)"
        case "hlg": "HLG"
        case "bt.1886", "srgb", "gamma2.2": "SDR"
        default: gamma.uppercased()
        }
    }
}
