import Foundation

extension DemoLibrary {
    private static let folderBuckets = [("A-F", "A", "F"), ("G-M", "G", "M"), ("N-S", "N", "S"), ("T-Z", "T", "Z")]
    private static let defaultPageSize = 50
    private static let recentlyAddedPerHub = 16
    private static let searchHubSize = 30

    func identityResponse(serverName: String) -> DemoResponse {
        .container(["size": 0, "claimed": true, "machineIdentifier": machineIdentifier, "version": "1.41.4.9463-630c9f557",
                    "friendlyName": serverName])
    }

    func sectionsResponse() -> DemoResponse {
        let directories = sections.map { section -> DemoJSON in
            ["key": section.id, "type": section.type, "title": section.title, "agent": "tv.plex.agents.\(section.type)",
             "language": "en-US", "refreshing": false, "uuid": "0000\(section.id)-aaaa-4bbb-8ccc-000000000\(section.id)", "hidden": 0]
        }
        return .container(["size": directories.count, "allowLibraryOrder": true, "title1": "Plex Library", "Directory": directories])
    }

    func sectionResponse(_ sectionID: String, what: String?, bucket: String?, request: DemoRequest) -> DemoResponse {
        guard let section = sections.first(where: { $0.id == sectionID }) else { return .notFound() }
        let keys = sectionItemKeys(sectionID)
        switch what {
        case nil:
            return .container(["size": 1, "Directory": [["key": sectionID, "type": section.type, "title": section.title]]])
        case "all":
            var selected = filter(keys, genre: request.first("genre"))
            selected = filter(selected, unwatched: request.flag("unwatched"), inProgress: request.flag("inProgress"))
            selected = ordered(selected, sort: request.first("sort"))
            var (fields, page) = paged(selected, request)
            fields["librarySectionID"] = Int(sectionID) ?? 0
            fields["librarySectionTitle"] = section.title
            fields["title1"] = section.title
            fields["viewGroup"] = section.type
            fields["Metadata"] = page.compactMap { render($0) }
            return .container(fields)
        case "firstCharacter":
            return firstCharacterResponse(keys, title: section.title)
        case "genre":
            let present = Set(keys.flatMap { items[$0]?.genres ?? [] }).sorted()
            let directories = present.map { genre -> DemoJSON in
                let id = genreIDs[genre] ?? 0
                return ["key": "\(id)", "title": genre, "type": "genre", "fastKey": "/library/sections/\(sectionID)/all?genre=\(id)"]
            }
            return .container(["size": directories.count, "allowSync": false, "title1": section.title, "Directory": directories])
        case "folder":
            return folderResponse(sectionID, keys: keys, bucket: bucket, title: section.title)
        default:
            return .notFound()
        }
    }

    private func firstCharacterResponse(_ keys: [String], title: String) -> DemoResponse {
        var counts = [String: Int]()
        for key in keys {
            let letter = String((items[key]?.titleSort ?? "").prefix(1)).uppercased()
            counts[letter.first?.isLetter == true ? letter : "#", default: 0] += 1
        }
        let letters = counts.keys.sorted { ($0 == "#" ? "\u{FFFF}" : $0) < ($1 == "#" ? "\u{FFFF}" : $1) }
        let directories = letters.map { ["key": $0, "title": $0, "size": counts[$0] ?? 0] as DemoJSON }
        return .container(["size": directories.count, "title1": title, "Directory": directories])
    }

    private func folderResponse(_ sectionID: String, keys: [String], bucket: String?, title: String) -> DemoResponse {
        func inBucket(_ key: String, _ range: (String, String, String)) -> Bool {
            let letter = String((items[key]?.titleSort ?? "").prefix(1)).uppercased()
            return range.1 <= letter && letter <= range.2
        }
        guard let bucket else {
            let directories = Self.folderBuckets.filter { range in keys.contains { inBucket($0, range) } }.map {
                ["key": "/library/sections/\(sectionID)/folder/\($0.0)", "title": $0.0] as DemoJSON
            }
            return .container(["size": directories.count, "title1": title, "Directory": directories])
        }
        guard let range = Self.folderBuckets.first(where: { $0.0 == bucket }) else { return .notFound() }
        let selected = keys.filter { inBucket($0, range) }.sorted { (items[$0]?.titleSort ?? "") < (items[$1]?.titleSort ?? "") }
        let metadata = selected.compactMap { render($0) }
        return .container(["size": metadata.count, "title1": title, "title2": bucket, "Metadata": metadata])
    }

    func metadataResponse(_ key: String, sub: String?) -> DemoResponse {
        guard let item = items[key] else { return .notFound() }
        switch sub {
        case nil:
            guard let full = render(key, full: true) else { return .notFound() }
            return .container(["size": 1, "Metadata": [full]])
        case "allLeaves":
            let leaves = leafKeys(of: key).compactMap { render($0) }
            return .container(["size": leaves.count, "totalSize": leaves.count, "key": key, "title1": item.title, "title2": item.title,
                               "viewGroup": "episode", "Metadata": leaves])
        case "children":
            let children = item.children.compactMap { render($0) }
            return .container(["size": children.count, "totalSize": children.count, "key": key,
                               "title1": item.fields.string("grandparentTitle") ?? item.title, "title2": item.title,
                               "viewGroup": item.kind == .show ? "season" : "episode", "Metadata": children])
        default:
            return .notFound()
        }
    }

    func hubsResponse(count: Int) -> DemoResponse {
        let hubs = [
            hub("home.continue", "Continue Watching", keys: Array(continueWatching().prefix(count))),
            hub("home.ondeck", "On Deck", keys: Array(onDeckKeys().prefix(count))),
            hub("home.recentlyadded", "Recently Added", keys: Array(recentlyAdded().prefix(max(count, Self.recentlyAddedPerHub)))),
        ]
        return .container(["size": hubs.count, "allowSync": true, "identifier": "com.plexapp.plugins.library", "Hub": hubs])
    }

    func sectionHubsResponse(_ sectionID: String) -> DemoResponse {
        guard let section = sections.first(where: { $0.id == sectionID }) else { return .notFound() }
        let pool = Set(sectionItemKeys(sectionID))
        func inSection(_ key: String) -> Bool {
            pool.contains(key) || items[key]?.fields.string("grandparentRatingKey").map(pool.contains) == true
        }
        let isMovie = section.type == "movie"
        let prefix = isMovie ? "movie" : "tv"
        var hubs = [hub("\(prefix).inprogress", "Continue Watching", keys: continueWatching().filter(inSection), kind: section.type)]
        if !isMovie { hubs.append(hub("tv.ondeck", "On Deck", keys: onDeckKeys().filter(inSection), kind: "episode")) }
        hubs.append(hub("\(prefix).recentlyadded", "Recently Added",
                        keys: Array(recentlyAdded().filter(pool.contains).prefix(Self.recentlyAddedPerHub)), kind: section.type))
        return .container(["size": hubs.count, "librarySectionID": Int(sectionID) ?? 0, "librarySectionTitle": section.title, "Hub": hubs])
    }

    func onDeckResponse() -> DemoResponse {
        let metadata = onDeckKeys().compactMap { render($0) }
        return .container(["size": metadata.count, "totalSize": metadata.count, "Metadata": metadata])
    }

    func recentlyAddedResponse(_ request: DemoRequest) -> DemoResponse {
        var (fields, page) = paged(recentlyAdded(), request)
        fields["Metadata"] = page.compactMap { render($0) }
        return .container(fields)
    }

    func searchResponse(_ query: String) -> DemoResponse {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return .container(["size": 0, "Hub": [DemoJSON]()]) }
        let episodes = orderedKeys.filter { items[$0]?.kind == .episode }
        var ranked = [(order: (Int, Int, String, Int), hub: DemoJSON)]()
        for (identifier, title, kind, pool) in [("movie", "Movies", "movie", movieKeys), ("show", "Shows", "show", showKeys),
                                                ("episode", "Episodes", "episode", episodes)] {
            let found = matches(pool, needle)
            if let best = found.first {
                let (matchClass, length, text) = rank(best, needle)
                ranked.append(((matchClass, length, text, ranked.count), hub(identifier, title, keys: Array(found.prefix(Self.searchHubSize)), kind: kind)))
            }
        }
        let hubs = ranked.sorted { $0.order < $1.order }.map(\.hub)
        return .container(["size": hubs.count, "Hub": hubs])
    }

    /// The keys whose title starts with the needle or has a word that does, best match first, the way Plex's search finds titles; a
    /// needle with a space may also sit inside a title.
    private func matches(_ keys: [String], _ needle: String) -> [String] {
        let spaced = needle.contains(" ")
        return keys
            .filter { key in
                let title = items[key]?.title.lowercased() ?? ""
                return rank(key, needle).0 < 2 || (spaced && title.contains(needle))
            }
            .sorted { rank($0, needle) < rank($1, needle) }
    }

    func historyResponse(_ request: DemoRequest) -> DemoResponse {
        var rows = history
        if let section = request.first("librarySectionID") {
            rows = rows.filter { String(items[$0.ratingKey]?.sectionID ?? 0) == section }
        }
        let ascending = (request.first("sort") ?? "viewedAt:desc").hasSuffix(":asc")
        rows.sort { ascending ? ($0.viewedAt, $0.id) < ($1.viewedAt, $1.id) : ($0.viewedAt, $0.id) > ($1.viewedAt, $1.id) }
        let start = max(0, request.int("X-Plex-Container-Start") ?? 0)
        let size = max(0, request.int("X-Plex-Container-Size") ?? Self.defaultPageSize)
        let page = rows.dropFirst(start).prefix(size).compactMap { historyEntry($0) }
        return .container(["size": page.count, "totalSize": rows.count, "offset": start, "Metadata": page])
    }

    func historyEntry(_ row: DemoHistoryRow) -> DemoJSON? {
        guard let item = items[row.ratingKey] else { return nil }
        let fields = item.fields
        var entry: DemoJSON = [
            "key": "/library/metadata/\(row.ratingKey)", "ratingKey": row.ratingKey, "type": fields.string("type") ?? "",
            "title": item.title, "viewedAt": row.viewedAt, "accountID": Self.accountID, "deviceID": 1 + (Int(row.ratingKey) ?? 0) % 3,
            "librarySectionID": item.sectionID, "librarySectionTitle": fields.string("librarySectionTitle") ?? "",
            "thumb": fields.string("thumb") ?? "", "historyKey": "/status/sessions/history/\(row.id)",
            "originallyAvailableAt": fields.string("originallyAvailableAt") ?? "",
        ]
        if item.kind == .episode, let show = item.show {
            entry["grandparentTitle"] = fields.string("grandparentTitle")
            entry["grandparentRatingKey"] = fields.string("grandparentRatingKey")
            entry["grandparentThumb"] = fields.string("grandparentThumb")
            entry["grandparentKey"] = "/library/metadata/\(show)"
            entry["parentTitle"] = fields.string("parentTitle")
            entry["parentRatingKey"] = fields.string("parentRatingKey")
            entry["parentIndex"] = fields.int("parentIndex")
            entry["index"] = fields.int("index")
        }
        return entry
    }

    func continueWatching() -> [String] {
        orderedKeys
            .compactMap { items[$0] }
            .filter { $0.isPlayable && $0.isInProgress }
            .sorted { $0.lastViewedAt == $1.lastViewedAt ? $0.ratingKey < $1.ratingKey : $0.lastViewedAt > $1.lastViewedAt }
            .map(\.ratingKey)
    }

    func recentlyAdded() -> [String] {
        let pool = movieKeys + showKeys
        return pool.enumerated()
            .sorted { (items[$0.element]?.addedAt ?? 0, $1.offset) > (items[$1.element]?.addedAt ?? 0, $0.offset) }
            .map(\.element)
    }

    private func rank(_ key: String, _ needle: String) -> (Int, Int, String) {
        let title = items[key]?.title.lowercased() ?? ""
        if title.hasPrefix(needle) { return (0, title.count, title) }
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(needle) }) { return (1, title.count, title) }
        return (2, title.count, title)
    }

    private func filter(_ keys: [String], genre: String?) -> [String] {
        guard let genre, !genre.isEmpty else { return keys }
        let wanted = Set(genre.split(separator: ",").map { token -> String in
            genreIDs.first(where: { String($0.value) == token })?.key ?? String(token)
        })
        return keys.filter { !wanted.isDisjoint(with: items[$0]?.genres ?? []) }
    }

    private func filter(_ keys: [String], unwatched: Bool, inProgress: Bool) -> [String] {
        var selected = keys
        if unwatched {
            selected = selected.filter { items[$0].map { !$0.isWatched && $0.viewOffset == 0 } ?? false }
        }
        if inProgress {
            selected = selected.filter { key in
                guard let item = items[key] else { return false }
                if item.kind == .show {
                    let viewed = item.fields.int("viewedLeafCount") ?? 0
                    return viewed > 0 && viewed < (item.fields.int("leafCount") ?? 0) || leafKeys(of: key).contains { items[$0]?.isInProgress == true }
                }
                return item.isInProgress
            }
        }
        return selected
    }

    private func ordered(_ keys: [String], sort: String?) -> [String] {
        let parts = (sort ?? "titleSort:asc").split(separator: ":", maxSplits: 1).map(String.init)
        let field = parts.first ?? "titleSort"
        let descending = parts.count > 1 && parts[1] == "desc"
        func number(_ key: String) -> Double {
            guard let item = items[key] else { return 0 }
            switch field {
            case "addedAt": return Double(item.addedAt)
            case "year": return Double(item.fields.int("year") ?? 0)
            case "rating": return item.fields.double("rating") ?? 0
            case "audienceRating": return item.fields.double("audienceRating") ?? 0
            case "lastViewedAt": return Double(item.lastViewedAt)
            default: return 0
            }
        }
        func text(_ key: String) -> String {
            field == "originallyAvailableAt" ? items[key]?.fields.string("originallyAvailableAt") ?? "" : items[key]?.titleSort ?? ""
        }
        let isNumeric = ["addedAt", "year", "rating", "audienceRating", "lastViewedAt"].contains(field)
        return keys.sorted { a, b in
            let order: ComparisonResult
            if isNumeric {
                order = number(a) == number(b) ? .orderedSame : (number(a) < number(b) ? .orderedAscending : .orderedDescending)
            } else {
                order = text(a) == text(b) ? .orderedSame : (text(a) < text(b) ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return (items[a]?.titleSort ?? "", a) < (items[b]?.titleSort ?? "", b) }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
    }

    private func paged(_ keys: [String], _ request: DemoRequest) -> (DemoJSON, [String]) {
        let start = max(0, request.int("X-Plex-Container-Start") ?? 0)
        let size = max(0, request.int("X-Plex-Container-Size") ?? Self.defaultPageSize)
        let page = Array(keys.dropFirst(start).prefix(size))
        return (["size": page.count, "totalSize": keys.count, "offset": start], page)
    }
}
