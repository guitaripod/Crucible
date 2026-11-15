import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// What Linux remembers about the demo beyond `DemoMode` and `DemoTour` (`TVDemoState`): whether the demo's welcome still
/// has to show. It is set when the demo starts and cleared when the welcome appears, so a demo resumed after a relaunch
/// never repeats it.
enum LinuxDemoState {
    private static let introPendingKey = "crucible_linux_demo_intro_pending"

    static var isIntroPending: Bool {
        UserDefaults.standard.bool(forKey: introPendingKey)
    }

    static func markIntroPending() {
        UserDefaults.standard.set(true, forKey: introPendingKey)
    }

    static func clearIntro() {
        UserDefaults.standard.removeObject(forKey: introPendingKey)
    }

    /// "2 of 4 done", the progress line of the You row and the tour.
    @MainActor
    static func progressText(for tour: DemoTour = .shared) -> String {
        String(localized: "\(tour.completedCount) of \(tour.steps.count) done")
    }
}

/// Asks before the demo ends (`presentLeaveDemoConfirmation`). Connecting a Plex server and leaving both end it, so both
/// ask: the tour, the demo's viewing history and its statistics are forgotten and cannot be brought back.
@MainActor
enum DemoLeave {
    static func confirm(connecting: Bool, in window: Window, then leave: @escaping () -> Void) {
        if connecting {
            AlertView.confirm(title: DemoCopy.connectTitle,
                              message: String(localized: "\(DemoCopy.connectBody) The demo, its viewing history and your tour progress are removed."),
                              confirm: String(localized: "Connect"), in: window, action: leave)
            return
        }
        AlertView.confirm(title: String(localized: "Leave the Demo?"),
                          message: String(localized: "The demo library, its viewing history and your tour progress are removed. You can try the demo again from the welcome screen."),
                          confirm: String(localized: "Leave the Demo"), in: window, action: leave)
    }
}

/// The demo tour (`TVDemoTourViewController`): the things worth trying, each Done or Show me, which goes there, then the ways
/// out of the demo, Connect your Plex server and Leave the Demo. Reached from the Demo library row at the top of You.
@MainActor
final class DemoTourScreen: SettingsScaffold {
    private enum RowID {
        static let connect = "demo.connect"
        static let leave = "demo.leave"

        static func step(_ step: DemoTourStep) -> String {
            "demo.step.\(step.rawValue)"
        }
    }

    private let payload: LaunchPayload
    private let panel = ContextPanel(content: .init(symbol: "testtube.2", title: DemoCopy.bannerTitle))

    init(payload: LaunchPayload) {
        self.payload = payload
        super.init(title: DemoCopy.tourTitle)
        installContext(panel)
        refresh()
    }

    /// Steps tick elsewhere (a library, Search, the player), so the list catches up whenever the tour shows again.
    override func screenDidAppear() {
        refresh()
    }

    private func refresh() {
        let tour = DemoTour.shared
        let progress = LinuxDemoState.progressText(for: tour)
        panel.content = .init(symbol: "testtube.2", title: DemoCopy.bannerTitle, status: progress, body: DemoCopy.introBody)
        var items = tour.steps.map { step in
            let done = tour.completed.contains(step)
            return RowItem(id: RowID.step(step), title: step.title, subtitle: step.detail,
                           value: done ? String(localized: "Done") : String(localized: "Show me"), symbol: Symbol(step.symbol),
                           accessory: done ? .checkmark : .chevron)
        }
        items.append(RowItem(id: RowID.connect, title: DemoCopy.connectTitle, subtitle: DemoCopy.connectBody, symbol: "server.rack", accessory: .chevron))
        items.append(RowItem(id: RowID.leave, title: String(localized: "Leave the Demo"), symbol: "rectangle.portrait.and.arrow.right", isDestructive: true))
        setRows(items)
    }

    override func rowSelected(_ id: String) {
        if let step = DemoTour.shared.steps.first(where: { RowID.step($0) == id }) {
            showMe(step)
            return
        }
        guard let window, id == RowID.connect || id == RowID.leave else { return }
        DemoLeave.confirm(connecting: id == RowID.connect, in: window) { [weak self] in self?.rootView?.onLeaveDemo?() }
    }

    /// Goes where `step` happens: a library tab, Search, Statistics on top of this screen, or the title Home would resume.
    /// Playback, browsing and search then tick the step themselves.
    private func showMe(_ step: DemoTourStep) {
        switch step {
        case .browse:
            rootView?.selectFirstLibrary()
        case .search:
            rootView?.select("search")
        case .statistics:
            navigation?.push(StatisticsScreen(api: payload.api))
        case .play:
            playResumeItem()
        case .whatToWatch, .poster, .download:
            break
        }
    }

    private func playResumeItem() {
        let buckets = HomeBuckets(hubs: payload.hubs.Hub)
        guard let item = (buckets.continueWatching + buckets.onDeck).first(where: HomeMediaRules.isPlayable) else {
            rootView?.selectFirstLibrary()
            return
        }
        rootView?.play(item: item, api: payload.api)
    }
}
