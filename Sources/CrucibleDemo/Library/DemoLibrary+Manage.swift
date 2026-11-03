import Foundation

/// The owner's tools against the demo library, so the demo shows them working: scans and refreshes are accepted (a scan
/// shows as a background task for a few seconds), Fix Match offers a few candidates, edits and artwork choices take effect
/// for the session, stopping a stream ends it, and deleting is refused the way a server with media deletion off refuses it.
extension DemoLibrary {
    static let scanSeconds: TimeInterval = 10

    func noteScan(sectionID: String) -> DemoResponse {
        let title = sections.first { $0.id == sectionID }?.title ?? sectionID
        scans[sectionID] = (title, Date())
        return .empty()
    }

    func matchesResponse(_ key: String, title: String?, year: Int?) -> DemoResponse {
        guard let item = items[key] else { return .notFound() }
        let name = (title?.isEmpty == false ? title : nil) ?? item.title
        let year = year ?? item.fields.int("year") ?? 2020
        let kind = item.kind == .show ? "show" : "movie"
        let results: [DemoJSON] = [
            ["guid": item.fields.string("guid") ?? "plex://\(kind)/demo-\(key)", "name": item.title, "year": item.fields.int("year") ?? year, "score": 100, "matched": true],
            ["guid": "plex://\(kind)/demo-\(key)-1", "name": name, "year": year - 11, "score": 84, "matched": false],
            ["guid": "plex://\(kind)/demo-\(key)-2", "name": "\(name): Behind the Scenes", "year": year, "score": 57, "matched": false],
        ]
        return .container(["size": results.count, "SearchResult": results])
    }

    func editFields(_ request: DemoRequest) -> DemoResponse {
        guard let key = request.first("id"), items[key] != nil else { return .notFound() }
        for field in ["title", "titleSort", "originalTitle", "summary"] {
            if let value = request.first("\(field).value") { items[key]?.fields[field] = value }
        }
        if let year = request.first("year.value").flatMap(Int.init) { items[key]?.set("year", year) }
        return .empty()
    }

    /// The title's own picture first, then a few from other titles to choose from.
    func artworkResponse(_ key: String, kind: String) -> DemoResponse {
        guard let item = items[key] else { return .notFound() }
        let field = kind == "posters" ? "thumb" : "art"
        let own = item.fields.string(field)
        let others = (movieKeys + showKeys).filter { $0 != key }.prefix(6).compactMap { items[$0]?.fields.string(field) }
        let choices = ([own].compactMap { $0 } + others).enumerated().map { index, path -> DemoJSON in
            ["key": path, "ratingKey": "demo-\(field)-\(index)|\(path)", "thumb": path, "selected": index == 0, "provider": index == 0 ? "local" : "demo"]
        }
        return .container(["size": choices.count, "Metadata": choices])
    }

    func selectArtwork(_ key: String, kind: String, url: String?) -> DemoResponse {
        guard items[key] != nil, let path = url?.split(separator: "|", maxSplits: 1).last.map(String.init) else { return .notFound() }
        items[key]?.fields[kind == "poster" ? "thumb" : "art"] = path
        return .empty()
    }

    func deleteHistoryRow(_ id: String) -> DemoResponse {
        guard let index = history.firstIndex(where: { String($0.id) == id }) else { return .notFound() }
        history.remove(at: index)
        return .empty()
    }

    func terminateSession(_ id: String?) -> DemoResponse {
        guard let id else { return .notFound() }
        stoppedSessions.insert(id)
        return .empty()
    }

    func activitiesResponse(now: Date = Date()) -> DemoResponse {
        let running = scans.filter { now.timeIntervalSince($0.value.at) < Self.scanSeconds }
        let activities = running.map { id, scan -> DemoJSON in
            let progress = Int(now.timeIntervalSince(scan.at) / Self.scanSeconds * 100)
            return ["uuid": "demo-scan-\(id)", "type": "library.update.section", "cancellable": true, "title": "Scanning \(scan.title)", "progress": progress]
        }
        return .container(["size": activities.count, "Activity": activities])
    }

    func cancelActivity(_ uuid: String) -> DemoResponse {
        scans.removeValue(forKey: String(uuid.dropFirst("demo-scan-".count)))
        return .empty()
    }

    static func updaterResponse() -> DemoResponse {
        .container(["size": 1, "canInstall": false, "Release": [[
            "version": "1.43.6.10123",
            "added": "Faster scanning of large libraries.\nBetter matching of anime episodes.",
            "fixed": "Subtitles could start a second late after a seek.",
            "state": "notify",
        ]]])
    }

    static func resourcesResponse(now: Date = Date()) -> DemoResponse {
        let at = Int(now.timeIntervalSince1970)
        return .container(["size": 1, "StatisticsResources": [[
            "at": at, "timespan": 6, "hostCpuUtilization": 18.4, "processCpuUtilization": 9.2,
            "hostMemoryUtilization": 41.0, "processMemoryUtilization": 6.5,
        ]]])
    }
}
