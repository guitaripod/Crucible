import Foundation

/// The owner's tools against the demo library, so the demo shows them working: scans and refreshes are accepted (a scan
/// shows as a background task for a few seconds), Fix Match offers a few candidates, edits and artwork choices take effect
/// for the session, stopping a stream ends it, and deleting is refused the way a server with media deletion off refuses it.
extension DemoLibrary {
    static let scanSeconds: TimeInterval = 10

    /// A show's server settings, the way Plex lists a show's advanced settings: id, label, type, default and the choices.
    static let showSettings: [(id: String, label: String, type: String, defaultValue: String, choices: String?)] = [
        ("episodeSort", "Episode sorting", "int", "-1", "-1:Library default|0:Oldest first|1:Newest first"),
        ("flattenSeasons", "Seasons", "int", "-1", "-1:Library default|0:Show|1:Hide"),
        ("audioLanguage", "Preferred audio language", "text", "", ":Account default|en:English|es:Spanish|ja:Japanese"),
        ("subtitleMode", "Auto-select subtitle mode", "int", "-1", "-1:Account default|0:Manually selected|1:Shown with foreign audio|2:Always enabled"),
        ("autoDeletionItemPolicyWatchedLibrary", "Delete episodes after playing", "int", "0", "0:Never|1:After a day|7:After a week|100:On next refresh"),
        ("useOriginalTitle", "Use original titles", "bool", "false", nil),
    ]

    func showPreferencesJSON(_ key: String) -> DemoJSON {
        let saved = showPreferences[key] ?? [:]
        let settings = Self.showSettings.map { spec -> DemoJSON in
            var setting: DemoJSON = ["id": spec.id, "label": spec.label, "summary": "", "type": spec.type, "default": spec.defaultValue,
                                     "value": saved[spec.id] ?? spec.defaultValue, "hidden": false, "advanced": false]
            if let choices = spec.choices { setting["enumValues"] = choices }
            return setting
        }
        return ["Setting": settings]
    }

    /// The show with its server settings, as `includePreferences=1` returns it.
    func metadataWithPreferences(_ key: String) -> DemoResponse {
        guard let item = items[key], var full = render(key, full: true) else { return .notFound() }
        if item.kind == .show { full["Preferences"] = showPreferencesJSON(key) }
        return .container(["size": 1, "Metadata": [full]])
    }

    func setShowPreferences(_ key: String, _ request: DemoRequest) -> DemoResponse {
        guard items[key]?.kind == .show else { return .notFound() }
        for spec in Self.showSettings {
            if let value = request.first(spec.id) { showPreferences[key, default: [:]][spec.id] = value }
        }
        return .empty()
    }

    func noteScan(sectionID: String) -> DemoResponse {
        let title = sections.first { $0.id == sectionID }?.title ?? sectionID
        let started = Date()
        scans[sectionID] = (title, started)
        events.scan(sectionID: sectionID, title: title, event: "started", progress: 0)
        Task {
            try? await Task.sleep(for: .seconds(Self.scanSeconds))
            await endScan(sectionID: sectionID, startedAt: started)
        }
        return .empty()
    }

    /// Announces the end of a scan that ran its course, unless it was cancelled or started again meanwhile.
    private func endScan(sectionID: String, startedAt: Date) {
        guard let scan = scans[sectionID], scan.at == startedAt else { return }
        events.scan(sectionID: sectionID, title: scan.title, event: "ended", progress: 100)
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
        let sectionID = String(uuid.dropFirst("demo-scan-".count))
        if let scan = scans.removeValue(forKey: sectionID) {
            events.scan(sectionID: sectionID, title: scan.title, event: "ended", progress: 100)
        }
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
