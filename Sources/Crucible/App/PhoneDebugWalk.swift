#if DEBUG
import CrucibleCore
import MidgarCore
import QuartzCore
import UIKit

/// Walks the app with no hand on it, for a real iPhone or iPad, where nothing can tap unless UI automation was switched on at the
/// device. `CRUCIBLE_WALK="3:whattowatch,5:ask=1,9:snapshot=taste,10:scroll,13:pro,15:snapshot=opened"` runs each step that many
/// seconds after the main screen appears. While it runs `PhoneFrameWatch` logs every frame the main thread kept the display waiting
/// for, and each `snapshot` writes the window to `Library/Logs/<name>.png` beside the log, so one `devicectl device copy from` of
/// `Library/Logs` brings back what the screen showed and how smoothly it got there.
///
/// The steps:
/// - `whattowatch` opens What to Watch from Home; `ask=<n>` asks its example n, `ask=<words>` those words (a comma ends a step).
/// - `show=<rating key>` opens that show's page, `previouslyon` its recap sheet, and `write` has the recap written.
/// - `unseal` reaches for the sealed part of the answer on screen, which opens the paywall.
/// - `pro` has Crucible Pro arrive for this launch, as after a purchase, so a sealed answer opens where it stands.
/// - `scroll` runs the front screen's list to its end and back.
/// - `dismiss` closes whatever is presented, and `snapshot=<name>` writes the window.
/// - `playlead` plays the title Home leads with, `title=<rating key>` opens a film's or (`title=<rating key>:episode`) an
///   episode's page and `play` presses Play on it, `upnext` plays what the show page in front would play, and `close` ends
///   the player. With the log's "ms after Play" lines these time a start; `CRUCIBLE_INSTANT=0` times it without Instant Start.
///
/// A step that cannot run where the walk stands says so in the log instead of doing something else.
@MainActor
enum PhoneDebugWalk {
    private struct Step {
        let delay: TimeInterval
        let action: String
        let argument: String?

        /// Reads `seconds:action` or `seconds:action=argument`.
        init?(_ text: Substring) {
            let parts = text.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let delay = TimeInterval(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            let call = parts[1].split(separator: "=", maxSplits: 1)
            guard let action = call.first else { return nil }
            self.delay = delay
            self.action = action.trimmingCharacters(in: .whitespaces)
            self.argument = call.count == 2 ? String(call[1]) : nil
        }
    }

    private static var hasStarted = false

    /// Starts the walk `CRUCIBLE_WALK` describes, once per launch, when the main screen is up.
    static func startIfRequested(on tabBar: TabBarController) {
        guard !hasStarted, let script = ProcessInfo.processInfo.environment["CRUCIBLE_WALK"] else { return }
        hasStarted = true
        PhoneFrameWatch.shared.start()
        for step in script.split(separator: ",").compactMap(Step.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak tabBar] in
                guard let tabBar else { return }
                let ran = run(step, on: tabBar)
                let name = step.argument.map { "\(step.action)=\($0)" } ?? step.action
                MidgarLog.notice("Debug walk: \(name)\(ran ? "" : " could not run here")", category: .lifecycle)
            }
        }
    }

    /// The screen a person would be looking at: the top of whatever is presented, else the top of the selected tab.
    private static func front(of tabBar: TabBarController) -> UIViewController {
        var top: UIViewController = tabBar
        while let presented = top.presentedViewController { top = presented }
        if top === tabBar { return tabBar.currentNavigation?.topViewController ?? tabBar }
        return (top as? UINavigationController)?.topViewController ?? top
    }

    private static func run(_ step: Step, on tabBar: TabBarController) -> Bool {
        let front = front(of: tabBar)
        switch step.action {
        case "whattowatch":
            tabBar.open(.home)
            tabBar.homeScreen?.openWhatToWatch()
            return tabBar.homeScreen != nil
        case "ask":
            guard let screen = front as? WhatToWatchViewController, let request = request(step.argument) else { return false }
            screen.ask(request)
        case "show":
            guard let key = step.argument, let navigation = tabBar.open(.home) else { return false }
            navigation.pushViewController(ShowDetailViewController(api: tabBar.api, showRatingKey: key), animated: true)
        case "previouslyon":
            guard let page = front as? ShowDetailViewController, let model = page.model else { return false }
            PreviouslyOnViewController.present(for: model, from: page)
        case "write":
            guard let sheet = front as? PreviouslyOnViewController else { return false }
            sheet.writeTheRecap()
        case "unseal":
            if let screen = front as? WhatToWatchViewController {
                screen.reachForTheSealedPicks()
            } else if let sheet = front as? PreviouslyOnViewController {
                sheet.reachForTheSealedRecap()
            } else {
                return false
            }
        case "pro":
            ProAccess.shared.apply(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "debug.walk")))
        case "playlead":
            guard tabBar.open(.home) != nil, let home = tabBar.homeScreen else { return false }
            home.playHighlightedTitle()
        case "title":
            guard let parts = step.argument?.split(separator: ":"), let key = parts.first, let navigation = tabBar.open(.home) else { return false }
            let page = MediaDetailViewController(api: tabBar.api, ratingKey: String(key), mediaType: parts.count > 1 ? String(parts[1]) : "movie")
            navigation.pushViewController(page, animated: true)
        case "play":
            guard let page = front as? MediaDetailViewController else { return false }
            page.play()
        case "upnext":
            guard let page = front as? ShowDetailViewController, page.canPerform(.play) else { return false }
            page.perform(.play)
        case "close":
            guard let player = PlayerCoordinator.current else { return false }
            player.close()
        case "scroll":
            return scroll(front)
        case "dismiss":
            return dismissTheTop(over: tabBar)
        case "snapshot":
            return snapshot(step.argument ?? "walk", of: tabBar)
        default:
            return false
        }
        return true
    }

    /// Closes only what was presented last, so a paywall over a sheet leaves the sheet up.
    private static func dismissTheTop(over tabBar: TabBarController) -> Bool {
        guard var top = tabBar.presentedViewController else { return false }
        while let presented = top.presentedViewController { top = presented }
        top.dismiss(animated: true)
        return true
    }

    /// The words to ask: the example a number names, else the words themselves.
    private static func request(_ argument: String?) -> String? {
        guard let argument, !argument.isEmpty else { return nil }
        guard let place = Int(argument) else { return argument }
        return WatchCopy.examples.indices.contains(place) ? WatchCopy.examples[place] : nil
    }

    /// Runs the largest list on `screen` to its end and back, the way the scroll view animates a jump, so every row on the way
    /// is built at speed.
    private static func scroll(_ screen: UIViewController) -> Bool {
        guard let list = lists(in: screen.view).max(by: { $0.bounds.height < $1.bounds.height }) else { return false }
        let top = CGPoint(x: list.contentOffset.x, y: -list.adjustedContentInset.top)
        let end = CGPoint(x: top.x, y: max(top.y, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom))
        list.setContentOffset(end, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { list.setContentOffset(top, animated: true) }
        return true
    }

    private static func lists(in view: UIView) -> [UIScrollView] {
        view.subviews.flatMap { subview in
            [subview as? UIScrollView].compactMap { $0 } + lists(in: subview)
        }
    }

    /// Writes the window as it stands to `Library/Logs/<name>.png`. The frame watch reports first and leaves the drawing out
    /// of the next stretch, so it is not held against the app.
    private static func snapshot(_ name: String, of tabBar: TabBarController) -> Bool {
        guard let window = tabBar.view.window else { return false }
        PhoneFrameWatch.shared.report("until \(name)")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        let file = CrucibleLog.directory.appendingPathComponent("\(name).png")
        defer { PhoneFrameWatch.shared.disregardWhatJustRan() }
        do {
            try image.pngData()?.write(to: file, options: .atomic)
            return true
        } catch {
            MidgarLog.error("Debug walk: the snapshot \(name) was not written: \(error)", category: .lifecycle)
            return false
        }
    }
}

/// Says how long the main thread kept the display waiting while a debug walk runs. A display link notes every frame that came
/// later than the one before it should have let it, logs each wait of 50 ms or more as it happens, and `report` logs the worst
/// wait and the late frames of the stretch since the last report.
@MainActor
final class PhoneFrameWatch: NSObject {
    static let shared = PhoneFrameWatch()

    private static let noticeable: CFTimeInterval = 0.05
    private static let lateBy = 1.5

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var frames = 0
    private var late = 0
    private var longWaits = 0
    private var disregarded = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Logs the stretch that just ended and begins the next.
    func report(_ stretch: String) {
        guard link != nil else { return }
        let summary = "\(frames) frames, worst wait \(Self.milliseconds(worst)) ms, \(late) late, \(longWaits) of 50 ms or more"
        MidgarLog.notice("Frame watch, \(stretch): \(summary)", category: .lifecycle)
        worst = 0
        frames = 0
        late = 0
        longWaits = 0
    }

    /// Leaves out the wait that work the walk itself just did on the main thread, drawing a snapshot, is about to show
    /// up as. The first frame after such work can still carry the time it was due at, so the two that follow are not counted.
    func disregardWhatJustRan() {
        disregarded = 2
    }

    private static func milliseconds(_ time: CFTimeInterval) -> Int {
        Int((time * 1000).rounded())
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        guard disregarded == 0 else {
            disregarded -= 1
            return
        }
        let wait = link.timestamp - last
        frames += 1
        worst = max(worst, wait)
        if wait > (link.targetTimestamp - link.timestamp) * Self.lateBy { late += 1 }
        guard wait >= Self.noticeable else { return }
        longWaits += 1
        MidgarLog.notice("Frame wait \(Self.milliseconds(wait)) ms", category: .lifecycle)
    }
}
#endif
