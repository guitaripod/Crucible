import Foundation

/// What the server decided about a stream before it starts (`/video/:/transcode/universal/decision`): copy the picture and
/// sound into a stream as they are, or convert them, and why. A general code from 2000 up means the server will not play
/// the title at all, which is how a remote stream without the pass Plex asks for is refused.
package struct PlaybackDecision: Sendable, Equatable {
    package let generalCode: Int?
    package let generalText: String?
    package let directPlayText: String?
    package let transcodeText: String?
    package let videoDecision: String?
    package let audioDecision: String?
    package let subtitleDecision: String?
    /// The transfer function of the picture the stream will carry, "smpte2084" or "arib-std-b67" when it stays HDR.
    package let videoTransfer: String?

    package init(
        generalCode: Int?,
        generalText: String?,
        directPlayText: String? = nil,
        transcodeText: String? = nil,
        videoDecision: String? = nil,
        audioDecision: String? = nil,
        subtitleDecision: String? = nil,
        videoTransfer: String? = nil
    ) {
        self.generalCode = generalCode
        self.generalText = generalText
        self.directPlayText = directPlayText
        self.transcodeText = transcodeText
        self.videoDecision = videoDecision
        self.audioDecision = audioDecision
        self.subtitleDecision = subtitleDecision
        self.videoTransfer = videoTransfer
    }

    package var isRefusal: Bool { (generalCode ?? 0) >= 2000 }

    /// Reads the decision from the server's JSON; codes may come as numbers or as strings.
    package static func parse(_ data: Data) -> PlaybackDecision? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else { return nil }
        let part = ((((container["Metadata"] as? [[String: Any]])?.first?["Media"] as? [[String: Any]])?.first?["Part"] as? [[String: Any]])?.first)
        let streams = part?["Stream"] as? [[String: Any]] ?? []
        func decision(for type: Int) -> String? {
            streams.first { int($0["streamType"]) == type && $0["decision"] != nil }?["decision"] as? String
        }
        return PlaybackDecision(
            generalCode: int(container["generalDecisionCode"]),
            generalText: container["generalDecisionText"] as? String,
            directPlayText: container["directPlayDecisionText"] as? String,
            transcodeText: container["transcodeDecisionText"] as? String,
            videoDecision: decision(for: 1),
            audioDecision: decision(for: 2),
            subtitleDecision: decision(for: 3),
            videoTransfer: streams.first { int($0["streamType"]) == 1 }?["colorTrc"] as? String
        )
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        if let number = value as? Double { return Int(number) }
        return nil
    }
}

package enum PlaybackDecisionCopy {
    package static let remotePass = String(localized: "Playing away from home needs Plex Pass or a Remote Watch Pass, on your Plex account or on the server owner's. On the same network as the server it plays free.", comment: "Message when the server refuses a remote stream because no pass covers it")

    /// What to tell the viewer when the server refuses to play: the pass Plex asks for away from home, or the server's own words.
    package static func refusalMessage(_ decision: PlaybackDecision) -> String {
        let text = decision.generalText ?? decision.transcodeText ?? ""
        if isPassRefusal(text) { return remotePass }
        guard !text.isEmpty else { return String(localized: "The server refused to play this title.", comment: "Message when the server refuses a stream without saying why") }
        return String(localized: "The server says: \(text)", comment: "Message quoting the server's reason for refusing a stream")
    }

    static func isPassRefusal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("plex pass") || lowered.contains("remote watch") || (lowered.contains("remote") && lowered.contains("pass"))
    }
}

/// One line of the Stream Info panel.
package struct StreamInfoLine: Hashable, Sendable {
    package let label: String
    package let value: String
}

/// Stream Info: how the title is reaching the screen, for the curious and for working out why something buffers.
package enum StreamInfo {
    package static let title = String(localized: "Stream Info", comment: "Title of the player panel that explains how the stream is played")

    package static func lines(
        stream: ResolvedStream,
        route: HomeServerRoute,
        quality: Preferences.Quality,
        audioId: Int?,
        subtitleId: Int?
    ) -> [StreamInfoLine] {
        var lines = [StreamInfoLine(label: String(localized: "Playback", comment: "Stream Info label"), value: method(stream))]
        lines.append(StreamInfoLine(label: String(localized: "Connection", comment: "Stream Info label"), value: route.title))
        if !stream.isDirectPlay {
            lines.append(StreamInfoLine(label: String(localized: "Quality", comment: "Stream Info label"), value: quality.title))
        }
        if let media = stream.media {
            let videoStream = media.Part?.first?.Stream?.first { $0.streamType == 1 }
            let video = [
                media.videoCodec?.uppercased(),
                Formatters.resolution(media.width, media.height),
                media.videoProfile?.uppercased(),
                videoStream?.frameRate.flatMap(frameRate),
            ]
                .compactMap { $0 }.joined(separator: " · ")
            if !video.isEmpty { lines.append(StreamInfoLine(label: String(localized: "Video", comment: "Stream Info label"), value: video)) }
            lines.append(StreamInfoLine(
                label: String(localized: "Dynamic Range", comment: "Stream Info label for HDR10, Dolby Vision, HLG or SDR"),
                value: dynamicRange(DynamicRange(videoStream), stream: stream)
            ))
            if let container = media.container?.uppercased() {
                lines.append(StreamInfoLine(label: String(localized: "File", comment: "Stream Info label for the file's container"), value: container))
            }
            if let bitrate = media.bitrate, bitrate > 0 {
                let mbps = String(format: "%.1f", locale: Formatters.interfaceLocale, Double(bitrate) / 1000)
                lines.append(StreamInfoLine(label: String(localized: "Bitrate", comment: "Stream Info label"), value: String(localized: "\(mbps) Mbps")))
            }
        }
        let audio = PlaybackTrackMenu.playingAudioId(stream.audioTracks, selectedId: audioId)
        if let track = stream.audioTracks.first(where: { $0.id == audio }) {
            lines.append(StreamInfoLine(label: String(localized: "Audio"), value: track.displayTitle ?? DetailFormat.languageName(track)))
        }
        let subtitle = stream.subtitles.first { $0.id != nil && $0.id == subtitleId }
        lines.append(StreamInfoLine(label: String(localized: "Subtitles"), value: subtitle.map { $0.displayTitle ?? DetailFormat.languageName($0) } ?? String(localized: "Off")))
        if let reason = stream.decision?.transcodeText ?? stream.decision?.directPlayText, !stream.isDirectPlay, !reason.isEmpty {
            lines.append(StreamInfoLine(label: String(localized: "Server", comment: "Stream Info label for the server's own explanation"), value: reason))
        }
        return lines
    }

    /// The file's range when the picture reaches the screen as it is; when the server converts it, what the conversion keeps.
    static func dynamicRange(_ source: DynamicRange, stream: ResolvedStream) -> String {
        guard !stream.isDirectPlay, let decision = stream.decision, decision.videoDecision == "transcode" else { return source.name }
        switch decision.videoTransfer?.lowercased() {
        case "smpte2084": return DynamicRange.hdr10.name
        case "arib-std-b67": return DynamicRange.hlg.name
        default:
            guard source.isHDR else { return DynamicRange.sdr.name }
            return String(localized: "SDR, converted from \(source.name)", comment: "Stream Info: the server turns an HDR picture into SDR, as in \"SDR, converted from Dolby Vision 7\"")
        }
    }

    /// "23.976 fps", "24 fps" or "59.94 fps".
    static func frameRate(_ rate: Double) -> String? {
        guard rate.isFinite, rate > 0 else { return nil }
        let number = rate.formatted(.number.precision(.fractionLength(0...3)).locale(Formatters.interfaceLocale))
        return String(localized: "\(number) fps", comment: "Stream Info: video frames per second, as in \"23.976 fps\"")
    }

    private static func method(_ stream: ResolvedStream) -> String {
        if stream.isDirectPlay { return String(localized: "Direct Play", comment: "Stream Info: the file plays as it is") }
        guard let decision = stream.decision else { return String(localized: "Converted by the Server", comment: "Stream Info: the server prepares the stream") }
        if decision.subtitleDecision == "burn" { return String(localized: "Converting Video, Subtitles Burned In", comment: "Stream Info playback method") }
        switch (decision.videoDecision, decision.audioDecision) {
        case ("copy", "copy"): return String(localized: "Direct Stream", comment: "Stream Info: picture and sound copied into a new stream")
        case ("copy", _): return String(localized: "Direct Stream, Converting Audio", comment: "Stream Info playback method")
        case ("transcode", _): return String(localized: "Converting Video", comment: "Stream Info playback method")
        default: return String(localized: "Converted by the Server", comment: "Stream Info: the server prepares the stream")
        }
    }
}
