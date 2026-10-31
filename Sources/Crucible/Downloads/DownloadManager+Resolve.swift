import CrucibleCore
import Foundation
import MidgarCore
import UIKit

extension DownloadManager {
    /// Resolving fetches the Plex plan + playlists over a foreground URLSession, which is suspended
    /// while the app is backgrounded. A background-task assertion buys ~30s so a hand-off between
    /// episodes (the resolve) can finish even when iOS woke us only for a background segment event.
    func performResolve(_ ratingKey: String, quality: DownloadQuality, refreshes: Int) async {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        let endAssertion = { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid } }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "crucible.resolve.\(ratingKey)") { endAssertion() }
        defer { resolving.remove(ratingKey); endAssertion(); pumpQueue() }
        guard let cfg = config else { return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        var plannedSessionID: String?
        do {
            let plan = try await DownloadResolver.plan(api: api, ratingKey: ratingKey, quality: quality)
            guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
            plannedSessionID = plan.sessionID
            transcodeSessions[ratingKey] = plan.sessionID
            applyPlanMetadata(at: idx, plan: plan)
            if let posterPath = plan.posterPath ?? items[idx].plexThumbPath {
                fetchPoster(path: posterPath, ratingKey: ratingKey, baseURL: cfg.baseURL, token: cfg.token)
            }
            let resolved = try await HLSDownloader.resolve(masterURL: plan.url, ratingKey: ratingKey)
            guard let liveIdx = index(ratingKey), items[liveIdx].state == .downloading else {
                abandonTranscodeSession(plan.sessionID, ratingKey: ratingKey)
                return
            }
            let dir = DownloadPaths.assetDir(ratingKey: ratingKey)
            let onDisk = Set(resolved.segments
                .map { HLSDownloader.localName(for: $0) }
                .filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) })
            let token = UUID().uuidString
            jobs[ratingKey] = SegmentJob(base: resolved.base, names: resolved.segments, onDisk: onDisk, token: token, refreshes: refreshes)
            cancelInflight(ratingKey, scope: .excluding(token))
            resolveRetries[ratingKey] = nil
            MidgarLog.notice("Download \(refreshes == 0 ? "started" : "resumed") key=\(ratingKey) quality=\(quality.shortLabel) segments=\(resolved.segments.count) onDisk=\(onDisk.count)", category: .persistence)
            enqueueAllSegments(ratingKey)
        } catch {
            guard index(ratingKey) != nil else {
                if let plannedSessionID { abandonTranscodeSession(plannedSessionID, ratingKey: ratingKey) }
                return
            }
            handleResolveFailure(ratingKey, error: error)
        }
    }

    /// A timeout/connectivity error during resolve is almost always the app being suspended mid
    /// hand-off, not a dead download — re-queue it rather than failing terminally. While backgrounded
    /// we simply wait for the next foreground entry; while active we retry a bounded number of times.
    private func handleResolveFailure(_ ratingKey: String, error: Error) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        jobs[ratingKey] = nil
        stopTranscodeSession(ratingKey)
        if isTransientNetworkError(error) {
            let backgrounded = UIApplication.shared.applicationState == .background
            if backgrounded {
                items[idx].state = .queued
                persist()
                emit(.changed)
                MidgarLog.notice("Resolve deferred (app backgrounded) key=\(ratingKey)", category: .persistence)
                return
            }
            let retries = (resolveRetries[ratingKey] ?? 0) + 1
            if retries <= Self.maxResolveRetries {
                resolveRetries[ratingKey] = retries
                items[idx].state = .queued
                persist()
                emit(.changed)
                MidgarLog.notice("Resolve retry \(retries)/\(Self.maxResolveRetries) key=\(ratingKey)", category: .persistence)
                scheduleResolveRetry()
                return
            }
        }
        resolveRetries[ratingKey] = nil
        failItem(ratingKey, message: error.localizedDescription)
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        let transient: Set<URLError.Code> = [
            .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
            .secureConnectionFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
        ]
        return transient.contains(urlError.code)
    }

    private func scheduleResolveRetry() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.pumpQueue()
        }
    }

    private func applyPlanMetadata(at idx: Int, plan: DownloadResolver.Plan) {
        items[idx].estimatedBytes = plan.estimatedBytes
        items[idx].durationMs = plan.durationMs > 0 ? plan.durationMs : items[idx].durationMs
        items[idx].markers = plan.markers
        if items[idx].summary == nil { items[idx].summary = plan.summary }
        if items[idx].viewOffsetMs == 0 { items[idx].viewOffsetMs = plan.initialViewOffsetMs }
        persist()
    }
}
