import Foundation

/// A request to show the paywall: which feature the user reached for, so the screen can say why.
package struct PaywallRequest: Equatable, Sendable {
    package var feature: ProFeature?

    package init(feature: ProFeature? = nil) {
        self.feature = feature
    }
}

/// The one place the app asks "does this install have Pro?". It holds the latest status from the store
/// behind it, refreshes it when the app comes to the front, and tells observers when it changes.
@MainActor
package final class ProAccess {
    package static let shared = ProAccess(provider: UnlockedProAccess())

    package typealias Observer = @MainActor (ProStatus) -> Void
    package typealias PaywallPresenter = @MainActor (PaywallRequest, @escaping @MainActor (Bool) -> Void) -> Void

    package private(set) var status: ProStatus
    package private(set) var provider: any ProAccessProviding
    package var paywallPresenter: PaywallPresenter?

    private var observers: [UUID: Observer] = [:]
    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    package init(provider: any ProAccessProviding) {
        self.provider = provider
        self.status = provider.isStoreBacked ? .unknown : .pro(.included)
    }

    package var isPro: Bool { status.isPro }

    package var isStoreBacked: Bool { provider.isStoreBacked }

    package func allows(_ feature: ProFeature) -> Bool { isPro }

    /// Replaces the store before the first screen appears. Source builds never call this and stay unlocked.
    package func install(_ provider: any ProAccessProviding) {
        updatesTask?.cancel()
        refreshTask?.cancel()
        self.provider = provider
        status = provider.isStoreBacked ? .unknown : .pro(.included)
        notify()
    }

    /// Loads the cached status, follows the store's updates and asks it for a fresh answer.
    package func start() {
        updatesTask?.cancel()
        let provider = provider
        updatesTask = Task { [weak self] in
            let cached = await provider.cachedStatus()
            self?.apply(cached, keepingProOnUnknown: true)
            for await update in provider.statusUpdates() {
                self?.apply(update)
            }
        }
        refresh()
    }

    /// Asks the store again, for instance when the app returns to the front.
    package func refresh() {
        guard provider.isStoreBacked else { return }
        refreshTask?.cancel()
        let provider = provider
        refreshTask = Task { [weak self] in
            if let fresh = await provider.refreshStatus() { self?.apply(fresh) }
        }
    }

    /// Waits for a fresh answer, used right after a purchase or a restore so the screen that asked sees Pro on.
    package func refreshNow() async {
        guard provider.isStoreBacked else { return }
        if let fresh = await provider.refreshStatus() { apply(fresh) }
    }

    package func apply(_ new: ProStatus, keepingProOnUnknown: Bool = false) {
        guard new != status else { return }
        if keepingProOnUnknown, new == .unknown { return }
        status = new
        AppLogger.info("Pro status is now \(new.logDescription)", .store)
        notify()
    }

    @discardableResult
    package func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    package func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    /// Runs `completion(true)` at once when Pro is on; otherwise shows the paywall and reports whether the user ended up with Pro.
    package func requestUnlock(_ feature: ProFeature?, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard !isPro else {
            completion(true)
            return
        }
        guard let paywallPresenter else {
            AppLogger.error("A paywall was requested before a screen could show it", .store)
            completion(false)
            return
        }
        paywallPresenter(PaywallRequest(feature: feature)) { [weak self] unlocked in
            if unlocked { self?.refresh() }
            completion(unlocked)
        }
    }

    private func notify() {
        for observer in observers.values { observer(status) }
    }
}

extension ProStatus {
    fileprivate var logDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .free: return "free"
        case .pro(let entitlement): return "pro (\(entitlement.kind), \(entitlement.productIdentifier))"
        }
    }
}

extension ProAccess {
    /// Chooses the store for this launch and starts it. Debug builds take a scripted store when the environment asks for one, so
    /// every purchase path can be driven without a sandbox account; otherwise the store the app passes in is used, and with none
    /// (a source build) everything stays unlocked.
    package func configureForLaunch(store: (any ProAccessProviding)?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        if let scripted = ScriptedProAccess.fromEnvironment(environment) {
            install(scripted)
            start()
            return
        }
        #endif
        if let store { install(store) }
        start()
    }
}
