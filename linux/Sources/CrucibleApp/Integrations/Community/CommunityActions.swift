import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// What a comment offers wherever it shows (`TVCommunityScreens`): like, react, report, edit and delete for the viewer's
/// own, the comment's text for a row, and its counts. Trakt's answer comes back through `.traktCommunityChanged`.
@MainActor
enum CommunityActions {
    static func toggleLike(_ comment: TraktComment, from view: View) {
        let liking = !TraktCommunity.shared.isLiked(comment.id)
        Task { [weak view] in
            do {
                _ = try await TraktCommunity.shared.setLiked(liking, comment)
            } catch {
                alert(TraktCopy.name, message: error.localizedDescription, from: view)
            }
        }
    }

    static func toggleReaction(_ reaction: TraktReaction, on commentID: Int, from view: View) {
        let active = !TraktCommunity.shared.reactions(of: commentID).contains(reaction)
        Task { [weak view] in
            do {
                try await TraktCommunity.shared.setReaction(reaction, active: active, on: commentID)
            } catch {
                alert(TraktCopy.name, message: error.localizedDescription, from: view)
            }
        }
    }

    /// The seven reactions, the viewer's own checked; choosing one adds it or takes it back.
    static func pickReaction(for commentID: Int, from view: View, anchor: Rect? = nil) {
        guard let window = view.window else { return }
        let mine = TraktCommunity.shared.reactions(of: commentID)
        let items = TraktReaction.allCases.map { reaction in
            MenuView.Item(id: reaction.rawValue, title: "\(reaction.emoji)  \(reaction.title)", isChecked: mine.contains(reaction))
        }
        let menu = MenuView(title: TraktCommunityCopy.react, items: items, anchor: anchor ?? Self.anchor(for: view))
        menu.onSelect = { [weak view] chosen in
            guard let view, let reaction = TraktReaction(rawValue: chosen.id) else { return }
            toggleReaction(reaction, on: commentID, from: view)
        }
        menu.present(in: window)
    }

    /// Trakt's reasons for reporting a comment; choosing one sends the report.
    static func report(_ comment: TraktComment, from view: View, anchor: Rect? = nil) {
        guard let window = view.window else { return }
        let items = TraktCommentReportReason.allCases.map { MenuView.Item(id: $0.rawValue, title: $0.title) }
        let menu = MenuView(title: TraktCommunityCopy.reportTitle, items: items, anchor: anchor ?? Self.anchor(for: view))
        menu.onSelect = { [weak view] chosen in
            guard let reason = TraktCommentReportReason(rawValue: chosen.id) else { return }
            Task { [weak view] in
                do {
                    try await TraktCommunity.shared.report(comment, reason: reason)
                    alert(TraktCommunityCopy.reported, message: nil, from: view)
                } catch {
                    alert(TraktCopy.name, message: error.localizedDescription, from: view)
                }
            }
        }
        menu.present(in: window)
    }

    static func confirmDelete(_ comment: TraktComment, from view: View, then: (() -> Void)? = nil) {
        guard let window = view.window else { return }
        AlertView.confirm(title: TraktCommunityCopy.deleteTitle, message: TraktCommunityCopy.deleteMessage, confirm: TraktCommunityCopy.delete, in: window) { [weak view] in
            Task { [weak view] in
                do {
                    try await TraktCommunity.shared.delete(comment)
                    then?()
                } catch {
                    alert(TraktCopy.name, message: error.localizedDescription, from: view)
                }
            }
        }
    }

    /// A comment's menu (right-click or the Menu key): like or unlike, react, then edit and delete for the viewer's own or
    /// report for anyone else's.
    static func presentMenu(for comment: TraktComment, at point: Point?, from view: ScreenView) {
        guard let window = view.window else { return }
        let community = TraktCommunity.shared
        let liked = community.isLiked(comment.id)
        var items = [
            MenuView.Item(id: "like", title: liked ? TraktCommunityCopy.unlike : TraktCommunityCopy.like, symbol: liked ? "heart.slash" : "heart"),
            MenuView.Item(id: "react", title: TraktCommunityCopy.react + "…", symbol: "face.smiling"),
        ]
        if community.isMine(comment) {
            items.append(MenuView.Item(id: "edit", title: TraktCommunityCopy.edit, symbol: "pencil"))
            items.append(MenuView.Item(id: "delete", title: TraktCommunityCopy.delete, symbol: "trash", isDestructive: true))
        } else {
            items.append(MenuView.Item(id: "report", title: TraktCommunityCopy.report + "…", symbol: "flag"))
        }
        let anchor = point.map { Rect(x: $0.x, y: $0.y, width: 1, height: 1) } ?? Self.anchor(for: view)
        let menu = MenuView(title: comment.user.displayName, items: items, anchor: anchor)
        menu.onSelect = { [weak view] chosen in
            guard let view else { return }
            switch chosen.id {
            case "like": toggleLike(comment, from: view)
            case "react": pickReaction(for: comment.id, from: view, anchor: anchor)
            case "edit": view.navigation?.push(CommentComposerScreen(mode: .edit(comment)))
            case "delete": confirmDelete(comment, from: view)
            case "report": report(comment, from: view, anchor: anchor)
            default: break
            }
        }
        menu.present(in: window)
    }

    /// "♥ 12  💬 3  😂 5" for a row's value: likes, replies when there are any, and the most given reaction.
    static func countsValue(_ comment: TraktComment, summary: TraktReactionSummary?) -> String {
        var parts = ["♥ \(Formatters.compactCount(comment.likeCount))"]
        if comment.replyCount > 0 { parts.append("💬 \(Formatters.compactCount(comment.replyCount))") }
        if let top = summary?.ranked.first { parts.append("\(top.reaction.emoji) \(Formatters.compactCount(top.count))") }
        return parts.joined(separator: "  ")
    }

    /// A comment's text for a row or a panel, spoilers hidden unless `revealed`.
    static func text(_ comment: TraktComment, revealed: Bool) -> String {
        if comment.isSpoiler && !revealed { return TraktCommunityCopy.spoilerCover + " · " + TraktCommunityCopy.pressToReveal }
        let text = TraktCommentText(comment.text)
        return revealed ? text.plainText : text.textHidingSpoilers
    }

    static func alert(_ title: String, message: String?, from view: View?) {
        guard let window = view?.window else { return }
        AlertView.notice(title: title, message: message, in: window)
    }

    /// Under the focused view, where a menu opened from the keyboard hangs.
    private static func anchor(for view: View) -> Rect {
        let frame = view.window?.focusedView?.frameInWindow ?? view.frameInWindow
        return Rect(x: frame.minX, y: frame.maxY, width: 1, height: 1)
    }
}
