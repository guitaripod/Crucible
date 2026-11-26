import CrucibleUI
import Foundation
import Kiln

/// The notifications inbox: day headings with unread, watched and read rows, as the YouTube page shows them.
@MainActor
final class GalleryInbox: View {
    let page = PageView()
    let list = InboxListView()
    let heading = ScreenTitleView(title: "Notifications", summary: "5 New",
                                  detail: "New videos from the channels you follow land here. What you read and hide stays on this computer.")
    let chips = ChipRowView()
    let status = StatusLineView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(page)
        page.topInset = Theme.current.metrics.tv(40)
        chips.setChips([
            .init(id: "all", title: "All 12", isSelected: true), .init(id: "videos", title: "Videos 9"),
            .init(id: "shorts", title: "Shorts 3"), .init(id: "unread", title: "Unread 5"),
            .init(id: "channels", title: "Channels", symbol: "person.2", opensMenu: true),
            .init(id: "markAll", title: "Mark All as Read", symbol: "checkmark.circle"),
            .init(id: "refresh", title: "Refresh", symbol: "arrow.clockwise"),
        ])
        let today = [
            row("lighthouse", title: "The Last Lighthouse · A Film About the Sea, the Dark and Everything Between",
                channel: "Ada Lindqvist", facts: "1.2M views · 2 hours ago", person: "ada lindqvist", unread: true),
            row("salt-flats", title: "We Mapped a Lake That Is No Longer There", channel: "Marco Bellini", facts: "486K views · 5 hours ago",
                person: "marco bellini", unread: true),
            row("orchard-ep1", title: "Winter Orchard · The First Frost", channel: "Noor Haddad", facts: "92K views · 7 hours ago · Watched",
                person: "noor haddad", watched: true),
        ]
        let yesterday = [
            row("neon", title: "Neon Tides: The Power Cut", channel: "Kenji Mori", facts: "210K views · Yesterday", person: "kenji mori", unread: true),
            row("ember", title: "Ember Run — Official Trailer", channel: "Elsa Varga", facts: "1.8M views · Yesterday", person: "elsa varga"),
        ]
        let earlier = [
            row("orchard-ep2", title: "What the Bees Know", channel: "Noor Haddad", facts: "77K views · 3 days ago", person: "noor haddad"),
            row("salt-flats", title: "A Second Look at the Salt Flats", channel: "Tomás Reyes", facts: "31K views · 6 days ago · Watched", person: "tomás reyes",
                watched: true),
        ]
        list.setSections([
            .init(title: "Today", detail: "2 new", items: today),
            .init(title: "Yesterday", detail: "1 new", items: yesterday),
            .init(title: "Earlier", detail: nil, items: earlier),
        ])
        page.setSections([heading, chips, status, list])
    }

    private func row(_ seed: String, title: String, channel: String, facts: String, person: String, unread: Bool = false,
                     watched: Bool = false) -> InboxRowItem {
        InboxRowItem(id: "\(seed)-\(title.hashValue)", title: title, channel: channel, facts: facts,
                     thumbnail: .url(GalleryArt.url("backdrop", seed)), avatar: .url(GalleryArt.url("person", person)),
                     isUnread: unread, isWatched: watched)
    }

    override var preferredFocusView: View? { list }

    override func layoutSubviews() {
        page.frame = bounds
    }
}
