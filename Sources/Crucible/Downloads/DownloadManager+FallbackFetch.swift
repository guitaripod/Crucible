import CrucibleCore
import Foundation
import UIKit

extension DownloadManager {
    /// In-process fetches stop when iOS suspends the app; a background-task assertion buys ~30s of
    /// grace after backgrounding, then the item is honestly re-queued (auto-resumes on foreground)
    /// and the Live Activity updates to Queued instead of freezing at a stale percentage.
    func suspendFallbackFetch(_ ratingKey: String) {
        guard fallbackFetchers[ratingKey] != nil, !continuedProcessingActive else { return }
        fallbackFetchers.removeValue(forKey: ratingKey)?.cancel()
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        jobs[ratingKey] = nil
        items[idx].state = .queued
        persist()
        emit(.changed)
        AppLogger.notice("Fallback fetch suspended (background time expired) key=\(ratingKey)", .persistence)
    }

    func startFallbackFetch(_ ratingKey: String, token: String) {
        if let idx = index(ratingKey) {
            submitContinuedTaskIfNeeded(title: items[idx].displayTitle)
        }
        fallbackFetchers[ratingKey]?.cancel()
        fallbackFetchers[ratingKey] = Task { @MainActor [weak self] in
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            let endAssertion = { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid } }
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "crucible.fallback.\(ratingKey)") { [weak self] in
                self?.suspendFallbackFetch(ratingKey)
                endAssertion()
            }
            if bgTask == .invalid, UIApplication.shared.applicationState == .background {
                self?.suspendFallbackFetch(ratingKey)
                return
            }
            defer {
                self?.fallbackFetchers[ratingKey] = nil
                endAssertion()
            }
            var fetched = 0
            while let self, !Task.isCancelled,
                  let job = self.jobs[ratingKey], job.token == token,
                  let idx = self.index(ratingKey), self.items[idx].state == .downloading {
                guard let name = job.names.first(where: { !job.onDisk.contains(HLSDownloader.localName(for: $0)) }) else { return }
                let local = HLSDownloader.localName(for: name)
                guard let url = HLSDownloader.segmentURL(name: name, base: job.base) else {
                    self.failItem(ratingKey, message: "Could not build segment URL")
                    return
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 90
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                do {
                    let (tmp, response) = try await URLSession.shared.download(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard !Task.isCancelled, self.jobs[ratingKey]?.token == token else { return }
                    guard (200...299).contains(status),
                          DownloadPaths.commitSegment(tempURL: tmp, ratingKey: ratingKey, name: local) else {
                        AppLogger.error("Fallback segment failed status=\(status) key=\(ratingKey) name=\(local)", .persistence)
                        self.handleSegmentError(ratingKey: ratingKey, token: token)
                        return
                    }
                    fetched += 1
                    if fetched == 1 || fetched % 25 == 0 {
                        AppLogger.notice("Fallback fetch progress key=\(ratingKey) fetched=\(fetched)", .persistence)
                    }
                    self.handleSegmentFinished(ratingKey: ratingKey, name: local, token: token)
                } catch {
                    guard !Task.isCancelled else { return }
                    AppLogger.error("Fallback segment error key=\(ratingKey): \(error.localizedDescription)", .persistence)
                    self.handleSegmentError(ratingKey: ratingKey, token: token)
                    return
                }
            }
        }
    }
}
