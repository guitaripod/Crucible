import Foundation

/// The owner's tools against the demo library, so the demo shows them working: scans and refreshes are accepted (a scan
/// shows as a background task for a few seconds), Fix Match offers a few candidates and takes the one picked, edits, artwork
/// choices, deletions and the server update take effect for the session, and stopping a stream ends it.
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

    /// The title takes the name, year and guid of the match picked, as a server does once it has fetched that match's metadata.
    func applyMatch(_ key: String, guid: String?, name: String?, year: Int?) -> DemoResponse {
        guard items[key] != nil, let guid, let name, !name.isEmpty else { return .notFound() }
        items[key]?.fields["guid"] = guid
        items[key]?.fields["title"] = name
        items[key]?.fields["titleSort"] = name.lowercased()
        if let year { items[key]?.set("year", year) }
        return .empty()
    }

    /// Removes a film with its extras, a show with its seasons and episodes, a season with its episodes, or one episode, and their
    /// plays in the watch history, for the rest of the session.
    func deleteItem(_ key: String) -> DemoResponse {
        guard let item = items[key], item.fields.string("type") != "clip" else { return .notFound() }
        let removed = Set([key] + item.children + item.children.flatMap { items[$0]?.children ?? [] } + (extraKeys[key] ?? []))
        for parent in [item.season, item.show].compactMap({ $0 }) {
            items[parent]?.children.removeAll(where: removed.contains)
        }
        for gone in removed { items[gone] = nil }
        movieKeys.removeAll(where: removed.contains)
        showKeys.removeAll(where: removed.contains)
        for show in episodeKeysByShow.keys { episodeKeysByShow[show]?.removeAll(where: removed.contains) }
        if item.kind == .show { episodeKeysByShow[key] = nil }
        extraKeys[key] = nil
        onDeck.removeAll(where: removed.contains)
        hiddenFromContinue.subtract(removed)
        history.removeAll { removed.contains($0.ratingKey) }
        recountAll()
        events.deleted(ratingKey: key, sectionID: String(item.sectionID), type: Self.timelineType(item.kind))
        return .empty()
    }

    /// The metadata type a server's timeline gives a title of `kind`.
    private static func timelineType(_ kind: DemoItem.Kind) -> Int {
        switch kind {
        case .movie: return 1
        case .show: return 2
        case .season: return 3
        case .episode: return 4
        }
    }

    /// Remembers the audio and subtitle tracks picked for a file, so the next look at the title has them selected. A subtitle of 0
    /// is none.
    func selectStreams(partID: Int, audio: Int?, subtitle: Int?) -> DemoResponse {
        var choice = streamSelections[partID] ?? DemoStreamChoice()
        if let audio { choice.audio = audio }
        if let subtitle { choice.subtitle = subtitle }
        streamSelections[partID] = choice
        return .empty()
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

    /// The release the server offers, until Install Now has put it on.
    func updaterResponse() -> DemoResponse {
        .container(["size": 1, "canInstall": !updateInstalled, "Release": [[
            "version": "1.43.6.10123",
            "added": "Faster scanning of large libraries.\nBetter matching of anime episodes.",
            "fixed": "Subtitles could start a second late after a seek.",
            "state": updateInstalled ? "installed" : "notify",
        ]]])
    }

    func installUpdate() -> DemoResponse {
        updateInstalled = true
        return .empty()
    }

    static func resourcesResponse(now: Date = Date()) -> DemoResponse {
        let at = Int(now.timeIntervalSince1970)
        return .container(["size": 1, "StatisticsResources": [[
            "at": at, "timespan": 6, "hostCpuUtilization": 18.4, "processCpuUtilization": 9.2,
            "hostMemoryUtilization": 41.0, "processMemoryUtilization": 6.5,
        ]]])
    }
}
