import Foundation

extension DemoLibrary {
    private static let extraSpecs: [(parent: String, key: String, title: String, subtype: String)] = [
        ("1001", "8101", "Halcyon: Official Trailer", "trailer"),
        ("1001", "8102", "Halcyon: The Making of", "behindTheScenes"),
        ("1002", "8103", "Deep Field: Official Trailer", "trailer"),
        ("1006", "8104", "Cold Meridian: Teaser", "trailer"),
    ]

    /// Adds the trailers and featurettes: clips of their own that play but sit in no library, found through the title they belong to.
    func installExtras() {
        for spec in Self.extraSpecs {
            guard let parent = items[spec.parent] else { continue }
            var fields: DemoJSON = [
                "ratingKey": spec.key, "key": "/library/metadata/\(spec.key)", "type": "clip", "subtype": spec.subtype,
                "title": spec.title, "titleSort": spec.title.lowercased(), "duration": clipMilliseconds,
                "librarySectionID": parent.sectionID, "addedAt": now,
            ]
            fields["thumb"] = parent.fields.string("art") ?? parent.fields.string("thumb")
            items[spec.key] = DemoItem(
                kind: .movie, fields: fields, genres: [], directors: [], writers: [], cast: [], related: [],
                media: DemoMediaFacts(width: 1920, height: 1080, hdr: false, size: 80_000_000), show: nil, season: nil
            )
            extraKeys[spec.parent, default: []].append(spec.key)
        }
    }

    func extrasJSON(of key: String) -> DemoJSON? {
        let clips = (extraKeys[key] ?? []).compactMap { render($0, full: true) }
        return clips.isEmpty ? nil : ["size": clips.count, "Metadata": clips]
    }
}
