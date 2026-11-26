import CrucibleUI
import Foundation
import Kiln

/// The notifications inbox: day headings over cards of new videos and comment replies, as the YouTube page shows them.
@MainActor
final class GalleryInbox: View {
    let page = PageView()
    let grid = InboxGridView()
    let heading = ScreenTitleView(title: "Notifications", summary: "5 New",
                                  detail: "New videos from the channels you follow, and replies to your comments when a browser is signed in, land here.")
    let chips = ChipRowView()
    let status = StatusLineView()

    init(short: Bool = false) {
        super.init()
        addSubview(page)
        page.topInset = Theme.current.metrics.tv(40)
        chips.setChips([
            .init(id: "all", title: "All 1,204", isSelected: true), .init(id: "videos", title: "Videos 1,150"),
            .init(id: "shorts", title: "Shorts 41"), .init(id: "comments", title: "Comments 13"),
            .init(id: "unread", title: "Unread 5"), .init(id: "channels", title: "Channels", symbol: "person.2", opensMenu: true),
            .init(id: "markAll", title: "Mark All as Read", symbol: "checkmark.circle"),
            .init(id: "refresh", title: "Refresh", symbol: "arrow.clockwise"),
        ])
        let today = [
            upload("lighthouse", title: "The Last Lighthouse · A Film About the Sea, the Dark and Everything Between",
                   channel: "Ada Lindqvist", facts: "1.2M views · 2 hours ago", person: "ada lindqvist", unread: true),
            comment("250", title: "“The way the light comes through that last window is the whole film in one shot.”",
                    channel: "Noor Haddad", age: "3 hours ago", person: "noor haddad", unread: true),
            upload("salt-flats", title: "We Mapped a Lake That Is No Longer There", channel: "Marco Bellini",
                   facts: "486K views · 5 hours ago", person: "marco bellini", unread: true, badge: "4K"),
            upload("orchard-ep1", title: "Winter Orchard · The First Frost", channel: "Noor Haddad", facts: "92K views · 7 hours ago",
                   person: "noor haddad", watched: true),
        ]
        let yesterday = [
            upload("neon", title: "Neon Tides: The Power Cut", channel: "Kenji Mori", facts: "210K views · Yesterday", person: "kenji mori",
                   unread: true),
            comment("251", title: "“I paused on the harbour sign for a full minute. Nobody designs a joke that well by accident.”",
                    channel: "Elsa Varga", age: "Yesterday", person: "elsa varga", unread: true, kind: "Mentioned you"),
            upload("ember", title: "Ember Run — Official Trailer", channel: "Elsa Varga", facts: "1.8M views · Yesterday",
                   person: "elsa varga"),
            upload("orchard-ep2", title: "What the Bees Know", channel: "Noor Haddad", facts: "77K views · Yesterday",
                   person: "noor haddad", badge: "Shorts"),
        ]
        let earlier = [
            comment("252", title: "“The sound of the bees in the last scene is doing something I can't explain.”", channel: "Tomás Reyes",
                    age: "3 days ago", person: "tomás reyes"),
            upload("orchard-ep3", title: "A Ladder Against the Sky", channel: "Noor Haddad", facts: "61K views · 4 days ago · Watched",
                   person: "noor haddad", watched: true),
            upload("salt-flats", title: "A Second Look at the Salt Flats", channel: "Tomás Reyes", facts: "31K views · 6 days ago",
                   person: "tomás reyes", watched: true),
        ]
        grid.setSections(short ? [.init(title: "Today", detail: "2 New", items: Array(today.prefix(2)))]
                               : [.init(title: "Today", detail: "3 New", items: today),
                                  .init(title: "Yesterday", detail: "2 New", items: yesterday),
                                  .init(title: "Earlier", detail: nil, items: earlier)])
        grid.moreTitle = "Show 60 More · 1,193 Left"
        page.setSections([heading, chips, status, grid])
    }

    private func upload(_ seed: String, title: String, channel: String, facts: String, person: String, unread: Bool = false,
                        watched: Bool = false, badge: String? = nil) -> InboxCardItem {
        InboxCardItem(id: "\(seed)-\(title.hashValue)", title: title, channel: channel, facts: facts,
                      thumbnail: .url(GalleryArt.url("backdrop", seed)), avatar: .url(GalleryArt.url("person", person)), badge: badge,
                      isUnread: unread, isWatched: watched, canMute: true)
    }

    private func comment(_ seed: String, title: String, channel: String, age: String, person: String, unread: Bool = false,
                         kind: String = "Replied to your comment") -> InboxCardItem {
        InboxCardItem(id: "comment-\(seed)", title: title, channel: channel, context: kind, facts: age,
                      thumbnail: .url(GalleryArt.url("backdrop", "lighthouse")), avatar: .url(GalleryArt.url("person", person)),
                      isComment: true, isUnread: unread)
    }

    override var preferredFocusView: View? { grid }

    override func layoutSubviews() {
        page.frame = bounds
    }
}
