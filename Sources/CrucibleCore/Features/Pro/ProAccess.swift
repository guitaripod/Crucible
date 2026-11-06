import Foundation
import MidgarCore

/// A request to show the paywall: which feature the user reached for, so the screen can say why.
package struct PaywallRequest: Equatable, Sendable {
    package var feature: ProFeature?
    /// The paywall opens because the Pro Week just ended, so it says so first.
    package var followsProWeek: Bool

    package init(feature: ProFeature? = nil, followsProWeek: Bool = false) {
        self.feature = feature
        self.followsProWeek = followsProWeek
    }
}

/// The one place the app asks "does this install have Pro?". It holds the latest status from the store
/// behind it, refreshes it when the app comes to the front, and tells observers when it changes.
@MainActor
package final class ProAccess {
    package static let shared = ProAccess(provider: UnlockedProAccess(), weekStore: .live(), demoWeekStore: .demo())

    package typealias Observer = @MainActor (ProStatus) -> Void
    package typealias PaywallPresenter = @MainActor (PaywallRequest, @escaping @MainActor (Bool) -> Void) -> Void

    package private(set) var status: ProStatus
    package private(set) var provider: any ProAccessProviding
    package var paywallPresenter: PaywallPresenter?

    private var observers: [UUID: Observer] = [:]
    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var weekTimer: Task<Void, Never>?
    private var weekStore: ProWeekStore
    private let deviceWeekStore: ProWeekStore
    private let demoWeekStore: ProWeekStore
    private let now: () -> Date

    /// The Pro Week as of the last check (`ProWeek`). Observers hear when it begins and when it ends.
    package private(set) var proWeekPhase: ProWeek.Phase

    /// - Parameters:
    ///   - weekStore: Where the Pro Week is remembered. Only the shared instance uses the live store; every other instance, as
    ///     in tests and previews, gets a throwaway one.
    ///   - demoWeekStore: Where the demo's own Pro Week is remembered while the demo runs.
    ///   - now: The clock, injectable for tests.
    package init(
        provider: any ProAccessProviding,
        weekStore: ProWeekStore = .ephemeral(),
        demoWeekStore: ProWeekStore = .ephemeral(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.status = provider.isStoreBacked ? .unknown : .pro(.included)
        self.weekStore = weekStore
        deviceWeekStore = weekStore
        self.demoWeekStore = demoWeekStore
        self.now = now
        proWeekPhase = ProWeek.phase(start: weekStore.start, now: now())
    }

    package private(set) var demoUnlocked = false

    /// Whether the user has paid for Pro, or has it included. The Pro screens and the paywall read this.
    package var isPro: Bool { status.isPro }

    /// Whether the Pro features work right now: Pro is on, the Pro Week is running, or the demo is, which unlocks everything on its
    /// fictional library. Every feature check reads this; only the purchase screens read `isPro`.
    package var hasFullAccess: Bool { status.isPro || demoUnlocked || proWeekPhase.isActive }

    /// When the Pro Week ends, while it runs for a viewer who has not bought Pro.
    package var proWeekEndsAt: Date? {
        guard !status.isPro, case .active(let endsAt) = proWeekPhase else { return nil }
        return endsAt
    }

    /// The week runs and its announcement has not reached the viewer yet.
    package var isProWeekAnnouncementDue: Bool {
        proWeekEndsAt != nil && !weekStore.wasAnnounced
    }

    /// The week is over for a viewer who did not buy Pro, and nothing has said so yet.
    package var isProWeekEndNoticeDue: Bool {
        guard !status.isPro, case .ended = proWeekPhase else { return false }
        return !weekStore.endNoticeShown
    }

    package func markProWeekAnnounced() {
        weekStore.wasAnnounced = true
    }

    package func markProWeekEndNoticeShown() {
        weekStore.endNoticeShown = true
    }

    /// Starts the Pro Week for a viewer the store says has no Pro and who never had a week on this device. Source builds and an
    /// unanswered store never start it. Returns true when it started now.
    @discardableResult
    package func startProWeekIfEligible() -> Bool {
        guard provider.isStoreBacked, status == .free, weekStore.start == nil else { return false }
        let start = now()
        weekStore.saveStart(start)
        MidgarLog.info("Pro Week started, ends \(start.addingTimeInterval(ProWeek.length))", category: .store)
        refreshProWeek()
        return true
    }

    /// Brings the phase up to date, tells observers when it changed, and wakes again when the week ends, so an app left open
    /// locks the Pro features on time.
    package func refreshProWeek() {
        let current = now()
        let phase = ProWeek.phase(start: weekStore.start, now: current)
        weekTimer?.cancel()
        if case .active(let endsAt) = phase {
            let delay = max(1, endsAt.timeIntervalSince(current))
            weekTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refreshProWeek()
            }
        }
        guard phase != proWeekPhase else { return }
        proWeekPhase = phase
        notify()
    }

    /// While the demo runs its Pro Week is its own, so previewing the free version there never starts or ends the device's one week;
    /// leaving the demo forgets the demo's week and brings the device's back.
    package func useDemoProWeek(_ inDemo: Bool) {
        let store = inDemo ? demoWeekStore : deviceWeekStore
        if !inDemo { demoWeekStore.forgetDemoWeek() }
        guard store !== weekStore else { return }
        weekStore = store
        refreshProWeek()
    }

    package func setDemoUnlocked(_ unlocked: Bool) {
        guard demoUnlocked != unlocked else { return }
        demoUnlocked = unlocked
        notify()
    }

    package var isStoreBacked: Bool { provider.isStoreBacked }

    package func allows(_ feature: ProFeature) -> Bool { hasFullAccess }

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

    #if DEBUG
    /// Begins the Pro Week's story again from `start`, notes unseen, or forgets the week with nil. For previews, screenshot runs and
    /// debug launches; not in release builds.
    package func stageProWeek(startedAt start: Date?) {
        weekStore.reset()
        if let start { weekStore.saveStart(start) }
        refreshProWeek()
    }
    #endif

    /// Asks the store again, for instance when the app returns to the front.
    package func refresh() {
        refreshProWeek()
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
        MidgarLog.info("Pro status is now \(new.logDescription)", category: .store)
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
        guard !hasFullAccess else {
            completion(true)
            return
        }
        guard let paywallPresenter else {
            MidgarLog.error("A paywall was requested before a screen could show it", category: .store)
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
        stageProWeekIfRequested(environment)
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

#if DEBUG
extension ProAccess {
    /// `CRUCIBLE_PRO_WEEK=<days>` starts the Pro Week that many days ago (a decimal works, and 7 or more is a week that has
    /// ended), with neither note seen; `none` and `CRUCIBLE_FRESH=1` forget it, as on a new install.
    private func stageProWeekIfRequested(_ environment: [String: String]) {
        let value = environment["CRUCIBLE_PRO_WEEK"]
        if let days = value.flatMap(Double.init) {
            stageProWeek(startedAt: now().addingTimeInterval(-days * 86_400))
            MidgarLog.notice("Debug session: Pro Week started \(days) days ago", category: .lifecycle)
        } else if value == "none" || environment["CRUCIBLE_FRESH"] == "1" {
            stageProWeek(startedAt: nil)
        }
    }
}
#endif
