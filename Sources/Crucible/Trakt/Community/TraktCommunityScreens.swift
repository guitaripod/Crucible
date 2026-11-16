import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
import MidgarCore
@preconcurrency import UIKit

/// Opens the community's screens and runs its actions from any screen on iPhone and iPad: comments, threads, the composer,
/// members, who is watching, and the likes, reactions, reports and deletions a comment's menu offers. What needs Pro asks for
/// it first.
@MainActor
enum TraktCommunityScreens {
    /// Runs `action` when the community is unlocked, after the paywall when it was not.
    static func unlocked(_ action: @escaping @MainActor () -> Void) {
        guard !TraktCommunity.shared.isUnlocked else { return action() }
        ProAccess.shared.requestUnlock(.traktCommunity) { unlocked in
            if unlocked { action() }
        }
    }

    static func openComments(on subject: TraktCommunitySubject, titleName: String, from host: UIViewController) {
        unlocked {
            let screen = TraktCommentsViewController(source: .subject(subject), titleName: titleName)
            push(screen, from: host)
        }
    }

    static func openAspect(_ aspect: TraktSentiments.Aspect, on subject: TraktCommunitySubject, titleName: String, from host: UIViewController) {
        unlocked {
            let screen = TraktCommentsViewController(source: .aspect(aspect, subject), titleName: titleName)
            push(screen, from: host)
        }
    }

    /// Opens a comment's thread; `isFree` opens one of the comments a viewer without Pro reads in full.
    static func openThread(_ comment: TraktComment, subject: TraktCommunitySubject?, titleName: String?, isFree: Bool = false, from host: UIViewController) {
        if isFree { return push(TraktCommentThreadViewController(comment: comment, subject: subject, titleName: titleName), from: host) }
        unlocked { push(TraktCommentThreadViewController(comment: comment, subject: subject, titleName: titleName), from: host) }
    }

    static func openMember(_ user: TraktUser, from host: UIViewController) {
        unlocked {
            let screen = TraktMemberViewController(user: user)
            let navigation = UINavigationController(rootViewController: screen)
            navigation.modalPresentationStyle = .pageSheet
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
            host.present(navigation, animated: true)
        }
    }

    static func openWatching(_ users: [TraktUser], titleName: String, from host: UIViewController) {
        unlocked {
            let screen = TraktMembersViewController(title: TraktCommunityCopy.watchingNowTitle, subtitle: titleName, users: users)
            let navigation = UINavigationController(rootViewController: screen)
            navigation.modalPresentationStyle = .pageSheet
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
            host.present(navigation, animated: true)
        }
    }

    /// Opens the composer for a new comment on `subject`, a reply to `parent`, or an edit of `editing`.
    static func compose(_ mode: TraktCommentComposerViewController.Mode, from host: UIViewController) {
        let composer = TraktCommentComposerViewController(mode: mode)
        let navigation = UINavigationController(rootViewController: composer)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        navigation.isModalInPresentation = true
        host.present(navigation, animated: true)
    }

    private static func push(_ screen: UIViewController, from host: UIViewController) {
        if let navigation = host.navigationController {
            navigation.pushViewController(screen, animated: true)
        } else {
            host.present(UINavigationController(rootViewController: screen), animated: true)
        }
    }

    // MARK: - Actions

    static func toggleLike(_ comment: TraktComment, from host: UIViewController) {
        let liking = !TraktCommunity.shared.isLiked(comment.id)
        if liking { Haptics.light() }
        Task { @MainActor [weak host] in
            do {
                try await TraktCommunity.shared.setLiked(liking, comment)
            } catch {
                host?.presentTraktMessage(error.localizedDescription)
            }
        }
    }

    static func toggleReaction(_ reaction: TraktReaction, on commentID: Int, from host: UIViewController) {
        let active = !TraktCommunity.shared.reactions(of: commentID).contains(reaction)
        Task { @MainActor [weak host] in
            do {
                try await TraktCommunity.shared.setReaction(reaction, active: active, on: commentID)
            } catch {
                host?.presentTraktMessage(error.localizedDescription)
            }
        }
    }

    /// Everything a comment's menu offers: like, react, reply, copy, share, open on Trakt, report, and edit and delete for the
    /// viewer's own.
    /// Translate, Show Original or Show Translation for a comment in another language, or nil for one in the reader's.
    static func translationAction(for comment: TraktComment) -> UIAction? {
        let center = TranslationCenter.shared
        let shown = center.presentation(for: comment)
        switch shown.phase {
        case .offer, .failed:
            return UIAction(title: TranslationCopy.translate, image: UIImage(systemName: "translate")) { _ in center.translate(comment) }
        case .translated:
            return UIAction(title: TranslationCopy.showOriginal, image: UIImage(systemName: "text.bubble")) { _ in center.toggleOriginal(comment) }
        case .original:
            return UIAction(title: TranslationCopy.showTranslation, image: UIImage(systemName: "translate")) { _ in center.toggleOriginal(comment) }
        case .translating, .none:
            return nil
        }
    }

    static func menu(for comment: TraktComment, subject: TraktCommunitySubject?, titleName: String?, from host: UIViewController, includesOpen: Bool = false) -> UIMenu {
        let community = TraktCommunity.shared
        var primary: [UIMenuElement] = []
        if includesOpen, !comment.isReply {
            primary.append(UIAction(title: TraktCommunityCopy.comments, image: UIImage(systemName: "bubble.left.and.bubble.right")) { [weak host] _ in
                guard let host else { return }
                openThread(comment, subject: subject, titleName: titleName, from: host)
            })
        }
        let liked = community.isLiked(comment.id)
        primary.append(UIAction(title: liked ? TraktCommunityCopy.unlike : TraktCommunityCopy.like, image: UIImage(systemName: liked ? "heart.slash" : "heart")) { [weak host] _ in
            guard let host else { return }
            toggleLike(comment, from: host)
        })
        if !comment.isReply {
            primary.append(UIAction(title: TraktCommunityCopy.reply, image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak host] _ in
                guard let host else { return }
                unlocked { compose(.reply(comment), from: host) }
            })
        }
        let react = TraktReactionMenu.menu(mine: community.reactions(of: comment.id)) { [weak host] reaction in
            guard let host else { return }
            toggleReaction(reaction, on: comment.id, from: host)
        }
        var share: [UIMenuElement] = [
            UIAction(title: TraktCommunityCopy.copyText, image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = TraktCommentText(TranslationCenter.shared.displayed(comment).text).plainText
            },
        ]
        if let translation = translationAction(for: comment) { share.insert(translation, at: 0) }
        if let url = comment.webURL {
            share.append(UIAction(title: TraktCommunityCopy.openOnTrakt, image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            })
        }
        var own: [UIMenuElement] = []
        if community.isMine(comment) {
            own.append(UIAction(title: TraktCommunityCopy.edit, image: UIImage(systemName: "pencil")) { [weak host] _ in
                guard let host else { return }
                compose(.edit(comment), from: host)
            })
            own.append(UIAction(title: TraktCommunityCopy.delete, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak host] _ in
                guard let host else { return }
                confirmDelete(comment, from: host)
            })
        } else {
            own.append(UIMenu(title: TraktCommunityCopy.report, image: UIImage(systemName: "flag"), children: TraktCommentReportReason.allCases.map { reason in
                UIAction(title: reason.title) { [weak host] _ in
                    guard let host else { return }
                    report(comment, reason: reason, from: host)
                }
            }))
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [react]),
            UIMenu(options: .displayInline, children: primary),
            UIMenu(options: .displayInline, children: share),
            UIMenu(options: .displayInline, children: own),
        ])
    }

    static func report(_ comment: TraktComment, reason: TraktCommentReportReason, from host: UIViewController) {
        Task { @MainActor [weak host] in
            do {
                try await TraktCommunity.shared.report(comment, reason: reason)
                Haptics.success()
                guard let host else { return }
                TraktToast.show(TraktCommunityCopy.reported, symbol: "flag.fill", in: host.navigationController?.view ?? host.view, belowBar: host.navigationController != nil)
            } catch {
                host?.presentTraktMessage(error.localizedDescription)
            }
        }
    }

    static func confirmDelete(_ comment: TraktComment, from host: UIViewController, then: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: TraktCommunityCopy.deleteTitle, message: TraktCommunityCopy.deleteMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: TraktCommunityCopy.delete, style: .destructive) { [weak host] _ in
            Task { @MainActor in
                do {
                    try await TraktCommunity.shared.delete(comment)
                    Haptics.success()
                    if let host {
                        TraktToast.show(TraktCommunityCopy.deleted, symbol: "trash", in: host.navigationController?.view ?? host.view, belowBar: host.navigationController != nil)
                    }
                    then?()
                } catch {
                    host?.presentTraktMessage(error.localizedDescription)
                }
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        host.present(alert, animated: true)
    }

    /// Opens a link from a comment in the browser, or on Trakt's site for Trakt's own links.
    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
