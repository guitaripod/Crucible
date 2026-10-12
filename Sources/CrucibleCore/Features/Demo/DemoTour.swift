import Foundation

/// One thing worth trying in the demo. Completing steps is how a new user learns what Crucible does; the first few unlock the soft paywall.
package enum DemoTourStep: String, CaseIterable, Sendable {
    case play
    case browse
    case search
    case statistics
    case poster
    case download

    package var title: String {
        switch self {
        case .play: return "Play something"
        case .browse: return "Browse a library"
        case .search: return "Search the library"
        case .statistics: return "Open Statistics"
        case .poster: return "Preview your Year in Review"
        case .download: return "Download an episode"
        }
    }

    package var detail: String {
        switch self {
        case .play: return "Resume the highlighted title and try Skip Intro."
        case .browse: return "Filter by genre and watch state, sort, and jump with the A–Z index."
        case .search: return "Results group by type, with a top result."
        case .statistics: return "Your viewing, drawn from your Plex history."
        case .poster: return "A poster of your year, ready to share."
        case .download: return "Save it to watch offline, with progress on the Lock Screen."
        }
    }

    package var symbol: String {
        switch self {
        case .play: return "play.circle"
        case .browse: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .statistics: return "chart.bar.xaxis"
        case .poster: return "sparkles.rectangle.stack"
        case .download: return "arrow.down.circle"
        }
    }

    /// The steps that exist on the current platform: downloads are an iPhone feature.
    package static func listed(isTV: Bool = AppPlatform.isTV) -> [DemoTourStep] {
        allCases.filter { isTV ? $0 != .download : true }
    }
}

/// Words the demo says on both platforms, in one place so the iPhone and Apple TV never drift apart.
package enum DemoCopy {
    package static let welcomeButton = "Try the demo"
    package static let welcomeCaption = "No server needed. Explore a fictional library."
    package static let introTitle = "Welcome to the demo"
    package static let introBody = "Everything here is fictional: the titles, the artwork and the viewing history. All of Crucible is unlocked so you can try it."
    package static let introStart = "Start exploring"
    package static let bannerTitle = "Demo library"
    package static let connectTitle = "Connect your Plex server"
    package static let connectBody = "Leave the demo and sign in with Plex to use Crucible with your own library."
    package static let tourTitle = "Demo tour"
    package static let finaleTitle = "Enjoying the demo?"
    package static let finaleBody = "Crucible is free to use with your own server. Crucible Pro adds unlimited downloads, full Statistics, the Year in Review poster and Top Shelf, once, for every device."
    package static let finaleKeepExploring = "Keep exploring"
    package static let finalePro = "See Crucible Pro"
}

/// The demo's guided tour: which steps the user has done, saved per demo session. When enough are done the soft paywall appears once.
@MainActor
package final class DemoTour {
    package static let shared = DemoTour()

    /// How many steps open the finale: enough to have seen playback, browsing and the headline features.
    package static let finaleThreshold = 4

    package typealias Observer = @MainActor () -> Void

    private static let completedKey = "crucible_demo_tour_completed"
    private static let finaleKey = "crucible_demo_tour_finale_shown"

    package var onFinale: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let isTV: Bool
    private var observers: [UUID: Observer] = [:]

    package init(defaults: UserDefaults = .standard, isTV: Bool = AppPlatform.isTV) {
        self.defaults = defaults
        self.isTV = isTV
    }

    package var steps: [DemoTourStep] { DemoTourStep.listed(isTV: isTV) }

    package var completed: Set<DemoTourStep> {
        let raw = defaults.stringArray(forKey: Self.completedKey) ?? []
        return Set(raw.compactMap(DemoTourStep.init(rawValue:))).intersection(steps)
    }

    package var completedCount: Int { completed.count }

    package var isComplete: Bool { completedCount == steps.count }

    package var finaleShown: Bool { defaults.bool(forKey: Self.finaleKey) }

    /// Starts a fresh tour, for a new demo session.
    package func begin() {
        defaults.removeObject(forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.finaleKey)
        notify()
    }

    package func reset() {
        begin()
    }

    /// Notes that the user did something the tour asks for. Does nothing outside the demo or for a step already done; the finale fires once.
    package func record(_ step: DemoTourStep, demoActive: Bool = DemoMode.shared.isActive) {
        guard demoActive, steps.contains(step) else { return }
        var done = completed
        guard done.insert(step).inserted else { return }
        defaults.set(done.map(\.rawValue).sorted(), forKey: Self.completedKey)
        notify()
        if done.count >= Self.finaleThreshold, !finaleShown {
            defaults.set(true, forKey: Self.finaleKey)
            onFinale?()
        }
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

    private func notify() {
        for observer in observers.values { observer() }
    }
}
