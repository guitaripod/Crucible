import CrucibleCore
import CrucibleDesign
import UIKit

/// The owner's server dashboard on Apple TV: how hard the server is working, what it is busy with (scans, refreshes,
/// conversions, each cancellable with Select) and whether a newer version of Plex Media Server is waiting, with its release
/// notes and Install. Refreshes every few seconds while it is open.
final class TVServerDashboardViewController: TVSettingsScaffold {
    private static let loadID = "dashboard.load"
    private static let idleID = "dashboard.idle"
    private static let versionID = "dashboard.version"
    private static let updateID = "dashboard.update"
    private static let checkID = "dashboard.check"
    private static let activityPrefix = "dashboard.activity."

    private let api: APIClient
    private let heading = TVSettingsHeading(
        title: ServerDashboardCopy.title,
        body: String(localized: "What your server is doing right now.", comment: "Explanation under the server dashboard's title")
    )
    private var sample: PlexResourceSample?
    private var activities: [PlexActivity] = []
    private var release: PlexServerRelease?
    private var version: String?
    private lazy var refreshSlot = makeTaskSlot()

    init(api: APIClient) {
        self.api = api
        super.init()
        title = ServerDashboardCopy.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSlot.run { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    override func rowDidSelect(_ id: String) {
        let api = api
        switch id {
        case Self.checkID:
            TVManageMenus.run(host: self) { [weak self] in
                try await LibraryManagement.checkForUpdates(api: api)
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
        case Self.updateID:
            showRelease()
        default:
            guard id.hasPrefix(Self.activityPrefix), let activity = activities.first(where: { Self.activityPrefix + $0.uuid == id }) else { return }
            cancel(activity)
        }
    }

    private func refresh() async {
        async let sample = try? LibraryManagement.load(api: api)
        async let activities = try? LibraryManagement.activities(api: api)
        async let release = try? LibraryManagement.availableUpdate(api: api)
        async let identity: PlexIdentity? = try? api.request(.identity)
        let loaded = await (sample, activities, release, identity)
        self.sample = loaded.0 ?? nil
        self.activities = loaded.1 ?? []
        self.release = loaded.2 ?? nil
        version = loaded.3?.MediaContainer.version ?? version
        render()
    }

    private func render() {
        var rows = [TVRowItem(id: Self.loadID, title: String(localized: "Load", comment: "Server dashboard row for CPU and memory use"), value: ServerDashboardCopy.loadText(sample), symbol: "gauge.with.dots.needle.33percent", isStatic: true)]
        if activities.isEmpty {
            rows.append(TVRowItem(id: Self.idleID, title: String(localized: "Nothing running", comment: "Server dashboard: the server has no background tasks"), symbol: "checkmark.circle", isStatic: true))
        } else {
            rows += activities.map { activity in
                TVRowItem(
                    id: Self.activityPrefix + activity.uuid,
                    title: activity.title ?? "",
                    subtitle: activity.subtitle,
                    value: activity.progress.map { "\($0)%" },
                    symbol: "gearshape.2",
                    isStatic: activity.cancellable != true
                )
            }
        }
        rows.append(TVRowItem(id: Self.versionID, title: String(localized: "Plex Media Server", comment: "Server dashboard row showing the server version"), value: version, symbol: "server.rack", isStatic: true))
        if let release {
            rows.append(TVRowItem(id: Self.updateID, title: String(localized: "Update Available", comment: "Server dashboard row when a server update is waiting"), value: release.version, symbol: "arrow.down.app", accessory: .chevron))
        }
        rows.append(TVRowItem(id: Self.checkID, title: String(localized: "Check for Updates", comment: "Server dashboard action"), symbol: "arrow.clockwise"))
        setRows(rows)
    }

    private func cancel(_ activity: PlexActivity) {
        guard activity.cancellable == true else { return }
        let api = api
        presentConfirmation(
            title: activity.title ?? "",
            message: String(localized: "Stops this task on your server.", comment: "Confirmation message for cancelling a server task"),
            confirmTitle: String(localized: "Cancel Task", comment: "Button that cancels a server task")
        ) { [weak self] in
            guard let self else { return }
            TVManageMenus.run(host: self) { [weak self] in
                try await LibraryManagement.cancel(activity, api: api)
                await self?.refresh()
            }
        }
    }

    private func showRelease() {
        guard let release, presentedViewController == nil else { return }
        let alert = UIAlertController(title: ServerDashboardCopy.releaseTitle(release), message: ServerDashboardCopy.releaseNotes(release), preferredStyle: .alert)
        let api = api
        alert.addAction(UIAlertAction(title: String(localized: "Later", comment: "Button that leaves a server update for later"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Install Now", comment: "Button that installs a server update"), style: .default) { [weak self] _ in
            guard let self else { return }
            TVManageMenus.run(host: self) { try await LibraryManagement.installUpdate(api: api) }
        })
        present(alert, animated: TVMotion.animationsEnabled)
    }
}
