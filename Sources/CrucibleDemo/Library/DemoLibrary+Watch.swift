import Foundation

extension DemoLibrary {
    private static let minimumSavedPosition = 3000
    private static let completionPercent = 92
    private static let clipEndTolerance = (before: 3000, after: 2000)

    func scrobble(_ key: String) {
        guard let item = items[key] else { return }
        let changed = mark(key, watched: true)
        if item.isPlayable { addPlay(key) }
        for leaf in changed { trackOnDeck(after: leaf) }
        save()
    }

    func unscrobble(_ key: String) {
        guard items[key] != nil else { return }
        _ = mark(key, watched: false)
        save()
    }

    /// Records where the player is. Stopping at the end of the title (or of the demo clip, which is all there is to play) finishes it.
    func timeline(_ key: String, timeMs: Int, durationMs: Int, state: String) {
        guard var item = items[key], item.isPlayable else { return }
        item.set("lastViewedAt", Int(Date().timeIntervalSince1970))
        items[key] = item
        if state == "stopped", durationMs > 0, isFinished(timeMs: timeMs, durationMs: durationMs) {
            _ = mark(key, watched: true)
            addPlay(key)
            trackOnDeck(after: key)
        } else if timeMs >= Self.minimumSavedPosition {
            items[key]?.set("viewOffset", timeMs)
        }
        recountAll()
        persistItem(key)
        save()
    }

    func progress(_ key: String, timeMs: Int) {
        guard var item = items[key], item.isPlayable, timeMs > 0 else { return }
        item.set("lastViewedAt", Int(Date().timeIntervalSince1970))
        item.set("viewOffset", timeMs)
        items[key] = item
        recountAll()
        persistItem(key)
        save()
    }

    private func isFinished(timeMs: Int, durationMs: Int) -> Bool {
        if timeMs * 100 >= durationMs * Self.completionPercent { return true }
        let tolerance = Self.clipEndTolerance
        return timeMs >= clipMilliseconds - tolerance.before && timeMs <= clipMilliseconds + tolerance.after
    }

    @discardableResult
    private func mark(_ key: String, watched: Bool) -> [String] {
        guard let item = items[key] else { return [] }
        let targets = item.kind == .show || item.kind == .season ? leafKeys(of: key) : [key]
        let stamp = Int(Date().timeIntervalSince1970)
        for target in targets {
            guard var leaf = items[target] else { continue }
            if watched {
                leaf.set("viewCount", leaf.viewCount + 1)
                leaf.set("lastViewedAt", stamp)
            } else {
                leaf.set("viewCount", nil)
            }
            leaf.set("viewOffset", nil)
            items[target] = leaf
            persistItem(target)
        }
        recountAll()
        return targets
    }

    private func addPlay(_ key: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        history.append(DemoHistoryRow(id: (history.map(\.id).max() ?? 0) + 1, ratingKey: key, viewedAt: stamp))
        persisted.plays.append(DemoPersistedState.Play(ratingKey: key, viewedAt: stamp))
    }

    private func persistItem(_ key: String) {
        guard let item = items[key] else { return }
        persisted.items[key] = DemoPersistedState.ItemState(
            viewCount: item.viewCount, viewOffset: item.viewOffset, lastViewedAt: item.lastViewedAt
        )
    }

    private func save() {
        persisted.onDeck = onDeck
        store.scheduleSave(persisted)
    }

    /// Keeps On Deck honest: once an episode is finished, its show's entry moves on to the next episode to watch.
    private func trackOnDeck(after key: String) {
        guard let episode = items[key], episode.kind == .episode, let show = episode.show else { return }
        let next = nextUnwatched(after: key)
        let existing = onDeck.firstIndex { items[$0]?.show == show }
        switch (existing, next) {
        case (let index?, let next?): onDeck[index] = next
        case (let index?, nil): onDeck.remove(at: index)
        case (nil, let next?): onDeck.insert(next, at: 0)
        case (nil, nil): break
        }
    }

    private func nextUnwatched(after key: String) -> String? {
        guard let show = items[key]?.show, let episodes = episodeKeysByShow[show], let index = episodes.firstIndex(of: key) else { return nil }
        return episodes.dropFirst(index + 1).first { items[$0]?.isWatched == false }
    }

    func onDeckKeys() -> [String] {
        var seen = Set<String>()
        var keys = [String]()
        for entry in onDeck {
            guard let item = items[entry] else { continue }
            let resolved = item.isWatched ? nextUnwatched(after: entry) : entry
            if let resolved, seen.insert(resolved).inserted { keys.append(resolved) }
        }
        return keys
    }

    /// The artwork file for a thumb, art or avatar path as the app asks for it.
    func imageFileName(forPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "actors", parts[1].hasSuffix(".jpg") {
            return "actor_\(parts[1])"
        }
        guard parts.count >= 4, parts[0] == "library", parts[1] == "metadata", let item = items[parts[2]] else { return nil }
        switch parts[3] {
        case "art":
            let owner = item.kind == .season || item.kind == .episode ? (item.show ?? item.ratingKey) : item.ratingKey
            return "backdrop_\(owner).jpg"
        case "thumb":
            return item.kind == .episode ? "still_\(item.ratingKey).jpg" : "poster_\(item.ratingKey).jpg"
        default:
            return nil
        }
    }
}
