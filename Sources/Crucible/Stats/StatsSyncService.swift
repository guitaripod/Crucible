import Foundation

/// Mirrors Plex watch history into the local GRDB store (newest-first, incremental) and runs the
/// progressive runtime/genre/leafCount enrichment pass.
struct StatsSyncService: Sendable {
    let api: APIClient
    let store: StatsStore

    private static let pageSize = 100
    private static let maxPages = 400

    func sync() async {
        do {
            var state = try await store.syncState()

            let currentTz = TimeZone.current.identifier
            if state.tzIdentifier != currentTz {
                try await store.recomputeLocalTimeColumns()
                state.tzIdentifier = currentTz
                try await store.saveSyncState(state)
            }

            let sectionTitles = await loadSectionTitles()
            let time = StatsTime()
            let wasComplete = state.historyComplete
            let highWater = wasComplete ? (state.highWaterViewedAt ?? 0) : 0

            var start = wasComplete ? 0 : max(0, state.backfillOffset - Self.pageSize)
            var pages = 0
            var newHigh = state.highWaterViewedAt ?? 0
            var newLow = state.lowWaterViewedAt ?? Int.max
            var caughtUp = false

            while pages < Self.maxPages {
                let response: PlexHistoryResponse = try await api.request(.history(start: start, size: Self.pageSize))
                let metadata = response.MediaContainer.Metadata ?? []
                if metadata.isEmpty {
                    caughtUp = true
                    break
                }

                var plays = [Play]()
                plays.reserveCapacity(metadata.count)
                for entry in metadata {
                    guard let ratingKey = entry.ratingKey, !ratingKey.isEmpty,
                          let viewedAt = entry.viewedAt, viewedAt > 0 else { continue }
                    if wasComplete && viewedAt < highWater { caughtUp = true }
                    plays.append(makePlay(entry, ratingKey: ratingKey, viewedAt: viewedAt, time: time, sectionTitles: sectionTitles))
                    newHigh = max(newHigh, viewedAt)
                    newLow = min(newLow, viewedAt)
                }
                try await store.insertPlays(plays)

                pages += 1
                start += metadata.count

                if wasComplete && caughtUp { break }
                if metadata.count < Self.pageSize {
                    caughtUp = true
                    break
                }
                let total = response.MediaContainer.totalSize ?? 0
                if total > 0 && start >= total {
                    caughtUp = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }

            let totalRows = try await store.totalRows()
            state.highWaterViewedAt = newHigh > 0 ? newHigh : state.highWaterViewedAt
            if newLow != Int.max {
                state.lowWaterViewedAt = min(state.lowWaterViewedAt ?? newLow, newLow)
            }
            state.totalRows = totalRows
            state.lastSyncAt = Int(Date().timeIntervalSince1970)
            if !wasComplete {
                state.backfillOffset = caughtUp ? 0 : start
            }
            if caughtUp { state.historyComplete = true }
            try await store.saveSyncState(state)

            AppLogger.info("Stats sync: \(totalRows) rows, \(pages) pages, complete=\(state.historyComplete)", .stats)
        } catch {
            AppLogger.error("Stats sync failed: \(error.localizedDescription)", .stats)
        }
    }

    /// Runs enrichment batches until nothing remains or the per-launch cap is hit.
    func enrichLoop(perLaunchCap: Int) async {
        var processed = 0
        while processed < perLaunchCap {
            let did = await enrichOnce(itemBatch: 40, showBatch: 20)
            if did == 0 { break }
            processed += did
        }
        if processed > 0 {
            AppLogger.info("Stats enrichment processed \(processed) items", .stats)
        }
    }

    private func enrichOnce(itemBatch: Int, showBatch: Int) async -> Int {
        var processed = 0
        let now = Int(Date().timeIntervalSince1970)

        if let items = try? await store.itemsNeedingRuntime(limit: itemBatch) {
            for item in items {
                if Task.isCancelled { return processed }
                try? await Task.sleep(for: .milliseconds(250))
                guard let meta = await fetchMetadata(ratingKey: item.ratingKey) else { continue }
                let isMovie = (meta.type ?? item.type) == "movie"
                let record = ItemMeta(ratingKey: item.ratingKey, durationMs: meta.duration, year: meta.year, enrichedAt: now)
                try? await store.saveItemMeta(record, genres: isMovie ? meta.genres : [])
                processed += 1
            }
        }

        if let shows = try? await store.showsNeedingMeta(limit: showBatch) {
            for showKey in shows {
                if Task.isCancelled { return processed }
                try? await Task.sleep(for: .milliseconds(250))
                guard let meta = await fetchMetadata(ratingKey: showKey) else { continue }
                let record = ShowMeta(ratingKey: showKey, leafCount: meta.leafCount, title: meta.title, thumb: meta.thumb, enrichedAt: now)
                try? await store.saveShowMeta(record, genres: meta.genres)
                processed += 1
            }
        }

        return processed
    }

    private func fetchMetadata(ratingKey: String) async -> PlexMetadata? {
        do {
            let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
            return container.Metadata?.first
        } catch {
            return nil
        }
    }

    private func loadSectionTitles() async -> [Int: String] {
        do {
            let container = try await api.requestContainer(.sections)
            var map = [Int: String]()
            for dir in container.Directory ?? [] {
                if let key = dir.key, let id = Int(key), let title = dir.title {
                    map[id] = title
                }
            }
            return map
        } catch {
            return [:]
        }
    }

    private func makePlay(_ entry: PlexHistoryEntry, ratingKey: String, viewedAt: Int, time: StatsTime, sectionTitles: [Int: String]) -> Play {
        let c = time.components(forViewedAt: viewedAt)
        let sectionTitle = entry.librarySectionTitle ?? entry.librarySectionID.flatMap { sectionTitles[$0] }
        return Play(
            id: nil,
            ratingKey: ratingKey,
            type: entry.type,
            title: entry.title,
            grandparentTitle: entry.grandparentTitle,
            grandparentRatingKey: entry.grandparentRatingKey,
            grandparentThumb: entry.grandparentThumb,
            thumb: entry.thumb,
            parentIndex: entry.parentIndex,
            idx: entry.index,
            viewedAt: viewedAt,
            dayEpoch: c.dayEpoch,
            hourLocal: c.hourLocal,
            weekday: c.weekday,
            monthEpoch: c.monthEpoch,
            monthDay: c.monthDay,
            year: c.year,
            librarySectionID: entry.librarySectionID,
            librarySectionTitle: sectionTitle,
            accountID: entry.accountID,
            deviceID: entry.deviceID
        )
    }
}
