import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// You: the account and server this computer uses, how big the interface is drawn, and signing out.
@MainActor
final class YouScreen: ScreenView {
    var onSignOut: (() -> Void)?
    var onSwitchServer: (() -> Void)?

    private let payload: LaunchPayload
    private let title = ScreenTitleView(title: String(localized: "You"))
    private let rows = RowListView()
    private let page = PageView()

    init(payload: LaunchPayload) {
        self.payload = payload
        super.init()
        addSubview(page)
        page.setSections([title, rows])
        rows.onSelect = { [weak self] item in self?.select(item.id) }
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        refresh()
    }

    override var preferredFocusView: View? { rows }

    private func refresh() {
        let theme = Theme.current
        title.summary = UserDefaults.standard.string(forKey: PlexAccountName.defaultsKey)
        rows.setItems([
            RowItem(id: "server", title: payload.connection.serverName, subtitle: payload.connection.serverURI.host, value: String(localized: "Switch Server"),
                    symbol: "server.rack", accessory: .chevron),
            RowItem(id: "density", title: String(localized: "Interface Size"),
                    subtitle: String(localized: "Desk draws the Apple TV design for a monitor; Couch draws it as on a TV across the room."),
                    value: theme.density == .desk ? String(localized: "Desk") : String(localized: "Couch"), symbol: "textformat.size"),
            RowItem(id: "appearance", title: String(localized: "Appearance"), value: theme.palette.appearance == .dark ? String(localized: "Dark") : String(localized: "Light"),
                    symbol: "circle.lefthalf.filled"),
            RowItem(id: "settings", title: String(localized: "Settings"), symbol: "gearshape", accessory: .chevron),
            RowItem(id: "signout", title: String(localized: "Sign Out"), symbol: "rectangle.portrait.and.arrow.right", isDestructive: true),
        ])
        setNeedsLayout()
    }

    private func select(_ id: String) {
        let theme = Theme.current
        switch id {
        case "server": onSwitchServer?()
        case "density":
            theme.density = theme.density == .desk ? .couch : .desk
            window?.relayoutEverything()
        case "appearance":
            theme.palette = theme.palette.appearance == .dark ? .light : .dark
            window?.background = theme.palette.canvas
            window?.relayoutEverything()
        case "settings": navigation?.push(SettingsScreen(api: payload.api))
        case "signout":
            guard let window else { return }
            AlertView.confirm(title: String(localized: "Sign Out"), message: String(localized: "Are you sure you want to sign out?"),
                              confirm: String(localized: "Sign Out"), in: window) { [weak self] in self?.onSignOut?() }
        default: break
        }
        refresh()
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}
