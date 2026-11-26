import CrucibleUI
import Foundation
import Kiln

/// The two places a count of new things shows: the floating tab bar and the desktop sidebar.
@MainActor
final class GalleryBadges: View {
    let tabBar = TabBarView()
    let sidebar = SidebarView()
    let note = Label("The YouTube destination carries the inbox count on the tab bar and, on a desk, in the sidebar.",
                     font: Theme.current.type.callout, color: Theme.current.palette.labelSecondary, maxLines: 3)

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(tabBar)
        addSubview(sidebar)
        addSubview(note)
        tabBar.tabs = [
            .init(id: "home", title: "Home", symbol: "house"),
            .init(id: "web", title: "YouTube", symbol: "play.rectangle"),
            .init(id: "search", title: "Search", symbol: "magnifyingglass"),
            .init(id: "you", title: "You", symbol: "person.crop.circle"),
        ]
        tabBar.select("web", animated: false)
        tabBar.setBadge(12, for: "web")
        sidebar.sections = [
            .init(items: [.init(id: "home", title: "Home", symbol: "house"), .init(id: "search", title: "Search", symbol: "magnifyingglass")]),
            .init(title: "Web", items: [.init(id: "web", title: "YouTube", symbol: "play.rectangle")]),
            .init(items: [.init(id: "you", title: "You", symbol: "person.crop.circle")]),
        ]
        sidebar.footer = [.init(id: "settings", title: "Settings", symbol: "gearshape")]
        sidebar.select("web")
        sidebar.setBadge(12, for: "web")
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        tabBar.frame = Rect(x: 0, y: 0, width: frame.width, height: metrics.tabBarTop + metrics.tabBarHeight + metrics.tv(20))
        sidebar.frame = Rect(x: metrics.sideMargin, y: tabBar.frame.maxY + metrics.tv(40), width: metrics.tv(430), height: 520)
        note.frame = Rect(x: sidebar.frame.maxX + metrics.sideMargin, y: sidebar.frame.minY + metrics.tv(40), width: 700, height: 80)
        note.setNeedsLayout()
    }
}
