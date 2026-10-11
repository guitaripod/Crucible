import Foundation
@testable import CrucibleCore

enum DetailFixtures {
    static func item(_ fields: [String: Any] = [:]) -> PlexMetadata {
        var merged: [String: Any] = ["ratingKey": "1", "type": "movie", "title": "Untitled"]
        merged.merge(fields) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: merged)
        return try! JSONDecoder().decode(PlexMetadata.self, from: data)
    }

    static func episode(
        _ number: Int,
        season: Int = 1,
        watched: Bool = false,
        offsetMs: Int? = nil,
        durationMs: Int = 2_400_000,
        title: String? = nil
    ) -> PlexMetadata {
        var fields: [String: Any] = [
            "ratingKey": "e\(season)\(number)",
            "type": "episode",
            "title": title ?? "Episode \(number)",
            "index": number,
            "parentIndex": season,
            "duration": durationMs,
        ]
        if watched { fields["viewCount"] = 1 }
        if let offsetMs { fields["viewOffset"] = offsetMs }
        return item(fields)
    }

    static func season(_ index: Int, watched: Int, total: Int, title: String? = nil) -> PlexMetadata {
        item([
            "ratingKey": "s\(index)",
            "type": "season",
            "title": title ?? "Season \(index)",
            "index": index,
            "leafCount": total,
            "viewedLeafCount": watched,
        ])
    }

    static func hub(_ titles: [PlexMetadata]) -> [String: Any] {
        ["Hub": [["hubIdentifier": "related", "Metadata": titles.map(json)]]]
    }

    static func json(_ item: PlexMetadata) -> [String: Any] {
        var fields: [String: Any] = ["ratingKey": item.id, "type": item.mediaType, "title": item.title]
        if let index = item.index { fields["index"] = index }
        if let parentIndex = item.parentIndex { fields["parentIndex"] = parentIndex }
        if let duration = item.duration { fields["duration"] = duration }
        if let viewOffset = item.viewOffset { fields["viewOffset"] = viewOffset }
        if let viewCount = item.viewCount { fields["viewCount"] = viewCount }
        if let leafCount = item.leafCount { fields["leafCount"] = leafCount }
        if let viewed = item.viewedLeafCount { fields["viewedLeafCount"] = viewed }
        return fields
    }

    static var richMedia: [[String: Any]] { [[
        "width": 3840,
        "height": 2160,
        "videoCodec": "hevc",
        "container": "mkv",
        "videoProfile": "main 10",
        "Part": [[
            "id": 1,
            "key": "/library/parts/1/file.mkv",
            "size": 4_294_967_296,
            "Stream": [
                ["id": 10, "streamType": 1, "codec": "hevc", "displayTitle": "4K HEVC HDR10"],
                ["id": 11, "streamType": 2, "codec": "eac3", "channels": 6, "language": "English", "displayTitle": "English (EAC3 5.1)", "selected": true, "default": true, "bitrate": 640],
                ["id": 12, "streamType": 2, "codec": "aac", "channels": 2, "language": "French", "displayTitle": "French (AAC Stereo)"],
                ["id": 13, "streamType": 3, "codec": "srt", "language": "English", "displayTitle": "English (SRT)", "default": true],
                ["id": 14, "streamType": 3, "codec": "pgssub", "language": "French", "displayTitle": "French (PGS)"],
            ],
        ]],
    ]] }
}
