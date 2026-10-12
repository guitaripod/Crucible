import Foundation

extension DemoLibrary {
    private static let partTimestamp = 1_700_000_000
    private static let introWindow = (start: 4000, end: 14000)
    private static let creditsLead = 9000
    private static let transcodeOnlyMargin = 6000

    private static let subtitleStreams: [(id: Int, language: String, code: String, tag: String, title: String, codec: String, selected: Bool, forced: Bool)] = [
        (101, "English", "eng", "en", "English (SRT)", "srt", true, false),
        (102, "English", "eng", "en", "English SDH (SRT)", "srt", false, false),
        (103, "Spanish", "spa", "es", "Spanish (SRT)", "srt", false, false),
        (104, "Finnish", "fin", "fi", "Finnish (SRT)", "srt", false, false),
        (105, "French", "fra", "fr", "French (PGS)", "hdmv_pgs_subtitle", false, false),
    ]

    func render(_ key: String, full: Bool = false) -> DemoJSON? {
        guard let item = items[key] else { return nil }
        var out = item.fields
        if item.kind == .movie || item.kind == .show || full, !item.genres.isEmpty {
            out["Genre"] = item.genres.map { ["id": genreIDs[$0] ?? 0, "tag": $0] as DemoJSON }
        }
        guard full else { return out }
        if !item.directors.isEmpty {
            out["Director"] = item.directors.enumerated().map { ["id": 7000 + $0.offset, "tag": $0.element] as DemoJSON }
        }
        if !item.writers.isEmpty {
            out["Writer"] = item.writers.enumerated().map { ["id": 7100 + $0.offset, "tag": $0.element] as DemoJSON }
        }
        switch item.kind {
        case .movie, .show:
            out["Role"] = item.cast
        case .episode:
            out["Role"] = Array((item.show.flatMap { items[$0] }?.cast ?? []).prefix(4))
        case .season:
            break
        }
        if item.isPlayable {
            out["Media"] = mediaJSON(item)
            out["Marker"] = markersJSON(item)
        }
        if !item.related.isEmpty {
            let related = item.related.compactMap { render($0) }
            let label = item.kind == .movie ? "Related Movies" : "Related Shows"
            out["Related"] = ["Hub": [[
                "type": item.fields.string("type") ?? "", "hubIdentifier": "\(item.fields.string("type") ?? "").similar",
                "title": label, "size": related.count, "more": false, "promoted": false, "Metadata": related,
            ] as DemoJSON]]
        }
        return out
    }

    /// A title whose saved position lies beyond the demo clip reports a container the app cannot direct play, so it transcodes
    /// (the server ignores the offset) instead of seeking past the end of a clip that is only seconds long.
    func canDirectPlay(_ item: DemoItem) -> Bool {
        item.viewOffset < clipMilliseconds - Self.transcodeOnlyMargin
    }

    private func mediaJSON(_ item: DemoItem) -> [DemoJSON] {
        guard let facts = item.media else { return [] }
        let key = item.ratingKey
        let id = Int(key) ?? 0
        let isMovie = item.kind == .movie
        let channels = isMovie ? 8 : 6
        let partID = 50000 + id
        let uhd = facts.height >= 2160
        var streams: [DemoJSON] = [
            ["id": id * 10 + 1, "streamType": 1, "codec": "h264", "language": "English", "languageCode": "eng",
             "bitrate": uhd ? 14200 : 8200, "selected": true, "default": true,
             "displayTitle": facts.hdr ? "4K (H.264 HDR10)" : "1080p (H.264)"],
            ["id": id * 10 + 2, "streamType": 2, "codec": "aac", "language": "English", "languageCode": "eng", "languageTag": "en",
             "channels": channels, "bitrate": 640, "selected": true, "default": true,
             "displayTitle": isMovie ? "English (EAC3 7.1)" : "English (AAC 5.1)", "title": "Surround"],
            ["id": id * 10 + 3, "streamType": 2, "codec": "aac", "language": "Spanish", "languageCode": "spa", "languageTag": "es",
             "channels": 6, "bitrate": 448, "default": false, "displayTitle": "Spanish (AAC 5.1)"],
            ["id": id * 10 + 4, "streamType": 2, "codec": "aac", "language": "English", "languageCode": "eng", "languageTag": "en",
             "channels": 2, "bitrate": 192, "default": false, "displayTitle": "English Commentary (AAC Stereo)", "title": "Commentary"],
        ]
        for subtitle in Self.subtitleStreams {
            let streamID = id * 10 + 5 + (subtitle.id - 101)
            var stream: DemoJSON = [
                "id": streamID, "streamType": 3, "codec": subtitle.codec, "language": subtitle.language,
                "languageCode": subtitle.code, "languageTag": subtitle.tag, "displayTitle": subtitle.title,
                "default": false, "forced": subtitle.forced, "selected": subtitle.selected,
            ]
            if subtitle.codec == "srt" {
                stream["format"] = "srt"
                stream["key"] = "/library/streams/\(streamID)"
            }
            streams.append(stream)
        }
        let container = canDirectPlay(item) ? "mp4" : "mkv"
        return [[
            "id": id, "duration": item.durationMs, "bitrate": uhd ? 14800 : 8800, "width": facts.width, "height": facts.height,
            "aspectRatio": 1.78, "audioChannels": channels, "audioCodec": "aac", "videoCodec": "h264",
            "videoResolution": uhd ? "4k" : "1080", "container": container, "videoFrameRate": "24p",
            "videoProfile": facts.hdr ? "main 10" : "high",
            "Part": [[
                "id": partID, "key": "/library/parts/\(partID)/\(Self.partTimestamp + id)/file.mp4", "duration": item.durationMs,
                "file": "/media/\(isMovie ? "movie" : "episode")s/\(key).\(container)", "size": facts.size, "container": container,
                "Stream": streams,
            ] as DemoJSON],
        ]]
    }

    /// Skip Intro and Skip Credits markers placed inside the demo clip, which is what every title actually plays.
    private func markersJSON(_ item: DemoItem) -> [DemoJSON] {
        let id = (Int(item.ratingKey) ?? 0) * 10
        var markers = [DemoJSON]()
        if item.kind == .episode {
            markers.append(["id": id + 1, "type": "intro", "startTimeOffset": Self.introWindow.start, "endTimeOffset": Self.introWindow.end])
        }
        markers.append([
            "id": id + 2, "type": "credits", "startTimeOffset": clipMilliseconds - Self.creditsLead,
            "endTimeOffset": clipMilliseconds, "final": true,
        ])
        return markers
    }

    func hub(_ identifier: String, _ title: String, keys: [String], kind: String = "mixed") -> DemoJSON {
        let metadata = keys.compactMap { render($0) }
        return ["type": kind, "hubIdentifier": identifier, "title": title, "size": metadata.count, "more": false,
                "promoted": true, "Metadata": metadata]
    }
}
