import Foundation

/// A collection of the fictional library: a name, the library it sits in and the titles inside it.
struct DemoCollection {
    let ratingKey: String
    let title: String
    let sectionID: String
    let summary: String
    let members: [String]
}

extension DemoLibrary {
    static let catalogueCollections = [
        DemoCollection(
            ratingKey: "9101", title: "Salvage Stories", sectionID: "1",
            summary: "Crews, wrecks and the people who go back for what was left behind.",
            members: ["1001", "1002", "1009", "1025"]
        ),
        DemoCollection(
            ratingKey: "9102", title: "After Dark", sectionID: "1",
            summary: "Thrillers best watched with the lights off.",
            members: ["1004", "1006", "1007", "1012", "1023"]
        ),
        DemoCollection(
            ratingKey: "9103", title: "Ice and Silence", sectionID: "3",
            summary: "Documentaries from the quietest places on the map.",
            members: ["1029", "1030", "1034"]
        ),
    ]

    /// The collections with the titles this viewer can see, leaving out any that would be empty.
    var collections: [DemoCollection] {
        Self.catalogueCollections.compactMap { collection in
            let members = collection.members.filter { items[$0] != nil }
            guard !members.isEmpty else { return nil }
            return DemoCollection(
                ratingKey: collection.ratingKey, title: collection.title, sectionID: collection.sectionID,
                summary: collection.summary, members: members
            )
        }
    }

    func collectionsResponse(sectionID: String, request: DemoRequest) -> DemoResponse {
        let keys = collections.filter { $0.sectionID == sectionID }.map { $0.ratingKey }
        var (fields, page) = paged(keys, request)
        fields["librarySectionID"] = Int(sectionID) ?? 0
        fields["Metadata"] = page.compactMap { key in collections.first { $0.ratingKey == key }.map(collectionJSON) }
        return .container(fields)
    }

    func collectionChildrenResponse(_ ratingKey: String, request: DemoRequest) -> DemoResponse {
        guard let collection = collections.first(where: { $0.ratingKey == ratingKey }) else { return .notFound() }
        var (fields, page) = paged(collection.members, request)
        fields["key"] = ratingKey
        fields["title1"] = collection.title
        fields["Metadata"] = page.compactMap { render($0) }
        return .container(fields)
    }

    func collectionTags(of key: String) -> [DemoJSON] {
        collections.filter { $0.members.contains(key) }.map { ["tag": $0.title] as DemoJSON }
    }

    private func collectionJSON(_ collection: DemoCollection) -> DemoJSON {
        let first = collection.members.compactMap { items[$0] }.first
        let section = sections.first { $0.id == collection.sectionID }
        var json: DemoJSON = [
            "ratingKey": collection.ratingKey, "key": "/library/collections/\(collection.ratingKey)/children",
            "guid": "collection://\(collection.ratingKey)", "type": "collection", "subtype": section?.type ?? "movie",
            "title": collection.title, "titleSort": collection.title.lowercased(), "summary": collection.summary,
            "smart": false, "childCount": collection.members.count,
            "librarySectionID": Int(collection.sectionID) ?? 0, "librarySectionTitle": section?.title ?? "",
            "addedAt": now - 30 * 86400, "updatedAt": now - 7 * 86400,
        ]
        json["thumb"] = first?.fields.string("thumb")
        json["art"] = first?.fields.string("art")
        return json
    }
}
