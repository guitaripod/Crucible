import CrucibleCore
import CrucibleDesign
import UIKit

/// The demo tour: the things worth trying with a check on each one done and a "Show me" that goes there, then the ways out of the
/// demo (connect a Plex server, look at Crucible Pro, leave). Reached from the "Demo library" row at the top of You.
final class TVDemoTourViewController: TVSettingsScaffold {
    private enum RowID {
        static let connect = "demo.connect"
        static let pro = "demo.pro"
        static let leave = "demo.leave"

        static func step(_ step: DemoTourStep) -> String {
            "demo.step.\(step.rawValue)"
        }
    }

    private let env: TVAppEnvironment
    private let heading = TVSettingsHeading(title: DemoCopy.tourTitle)
    private var tourObserver: UUID?

    init(env: TVAppEnvironment) {
        self.env = env
        super.init()
        title = DemoCopy.tourTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let tourObserver {
            Task { @MainActor in DemoTour.shared.stopObserving(tourObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        tourObserver = DemoTour.shared.observe { [weak self] in self?.refresh() }
        refresh()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        refresh()
    }

    override func rowDidSelect(_ id: String) {
        if let step = DemoTour.shared.steps.first(where: { RowID.step($0) == id }) {
            showMe(step)
            return
        }
        switch id {
        case RowID.connect: presentLeaveDemoConfirmation(connecting: true) { [session = env.session] in session.leaveDemo() }
        case RowID.pro: openPro()
        case RowID.leave: presentLeaveDemoConfirmation(connecting: false) { [session = env.session] in session.leaveDemo() }
        default: break
        }
    }

    /// The offer for an install that has not bought Pro; an owner has nothing to buy and would see the paywall close at once, so
    /// they get their plan instead.
    private func openPro() {
        guard ProAccess.shared.isPro else {
            TVPaywallViewController.present(PaywallRequest(), from: self) { _ in }
            return
        }
        TVNavigation.push(TVScreens.settings(env, page: .pro), from: self)
    }

    private func refresh() {
        let tour = DemoTour.shared
        heading.setBody(TVDemoState.progressText(for: tour))
        var rows = tour.steps.map { step in
            let done = tour.completed.contains(step)
            return TVRowItem(
                id: RowID.step(step),
                title: step.title,
                subtitle: step.detail,
                value: done ? "Done" : "Show me",
                symbol: step.symbol,
                accessory: done ? .checkmark : .chevron
            )
        }
        rows.append(TVRowItem(id: RowID.connect, title: DemoCopy.connectTitle, subtitle: DemoCopy.connectBody, symbol: "server.rack", accessory: .chevron))
        if ProAccess.shared.isStoreBacked {
            rows.append(TVRowItem(id: RowID.pro, title: DemoCopy.finalePro, symbol: "sparkles", accessory: .chevron))
        }
        rows.append(TVRowItem(id: RowID.leave, title: "Leave the Demo", symbol: "rectangle.portrait.and.arrow.right", isDestructive: true))
        setRows(rows)
    }

    /// Takes the person to the place where `step` happens: the library and search tabs, Statistics on top of this screen, or the
    /// title Home would resume. Playback, browsing and search then tick the step themselves.
    private func showMe(_ step: DemoTourStep) {
        switch step {
        case .browse:
            env.router.show(.library)
        case .search:
            env.router.show(.search)
        case .statistics:
            TVNavigation.push(TVScreens.statistics(env), from: self)
        case .play:
            playResumeItem()
        case .poster, .download:
            break
        }
    }

    private func playResumeItem() {
        let buckets = HomeBuckets(hubs: env.hubs.Hub)
        guard let item = (buckets.continueWatching + buckets.onDeck).first(where: HomeMediaRules.isPlayable) else {
            env.router.show(.library)
            return
        }
        env.router.play(TVPlaybackRequest(item: item))
    }
}
