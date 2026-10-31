import CrucibleCore
import Foundation
import MidgarCore
import UIKit

extension DownloadManager {
    // MARK: - Lifecycle

    func configure(baseURL: URL, token: String) {
        config = Config(baseURL: baseURL, token: token)
        pumpQueue()
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        registerContinuedProcessing()
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.endStale()
        #endif
        LocalMediaServer.shared.start()
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.store.load()
            self.items = loaded
            self.recoverLiveTasks()
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completionHandler(); return }
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    func handleEnteredForeground() {
        MidgarLog.notice("Entered foreground; \(activeDownloadCount) active downloads", category: .lifecycle)
        resolveRetries.removeAll()
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.sync(items: items, force: true)
        #endif
        for item in items where item.state == .downloading {
            if let job = jobs[item.ratingKey], fallbackFetchers[item.ratingKey] == nil {
                scheduleStallWatchdog(item.ratingKey, token: job.token)
            }
        }
        pumpQueue()
    }

    func handleSignOut() {
        deleteAll()
        config = nil
    }

    // MARK: - Observers

    @discardableResult
    func addObserver(_ handler: @escaping (DownloadEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    func emit(_ event: DownloadEvent) {
        for handler in observers.values { handler(event) }
        #if os(iOS) && canImport(ActivityKit)
        let needsForeground = backgroundSessionBroken && UIApplication.shared.applicationState == .background
        if case .progress = event {
            liveActivity.sync(items: items, force: false, needsForeground: needsForeground)
        } else {
            liveActivity.sync(items: items, force: true, needsForeground: needsForeground)
        }
        #endif
    }
}
