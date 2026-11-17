import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

extension TVDetailViewController {
    /// The invitation to connect Trakt shown where this title's community would be, while Trakt is not connected and the viewer has
    /// not put it away. Only a page that has a community has one.
    var traktInvite: TraktInvite? {
        guard communityKey != nil else { return nil }
        return TraktInvite.current(titleName: content?.header.title ?? "")
    }

    static func traktInviteSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(320))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.shelfTopInset, leading: 0, bottom: TVMetrics.shelfBottomInset, trailing: 0)
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(TVMetrics.shelfHeaderHeight)),
                elementKind: TVShelf.headerKind,
                alignment: .top
            ),
        ]
        return section
    }

    /// Fills the invitation's cell, updating the panel it already hosts so a refresh keeps the focus on its button.
    func configureTraktInvite(_ cell: TVHostCell) {
        guard let invite = traktInvite else { return }
        if let existing = cell.hosted as? TVTraktInviteView {
            existing.apply(invite)
            return
        }
        let panel = TVTraktInviteView(
            onConnect: { [weak self] in self?.openTraktFromInvite() },
            onNotNow: { [weak self] in self?.putTraktInviteAway() }
        )
        panel.apply(invite)
        cell.host(panel)
    }

    /// Trakt connected, disconnected or signed Crucible out while the page exists: a page on screen reads itself again so the
    /// scores and the community come or go; one under another screen does so when it comes back.
    func traktAccountChanged() {
        let status = TraktAccount.shared.status
        guard status != shownTraktStatus else { return }
        shownTraktStatus = status
        guard viewIfLoaded?.window != nil else { return }
        reload()
        refreshCommunity()
    }

    private func openTraktFromInvite() {
        MidgarLog.notice("Trakt invitation opened from a title page", category: .trakt)
        TVNavigation.push(TVTraktSettingsViewController(), from: self)
    }

    /// Not Now puts the invitation away on this Apple TV and dissolves it out of the page; the focus moves on to what follows it
    /// instead of jumping back to the top.
    private func putTraktInviteAway() {
        WelcomeLedger.shared.dismissTraktInvite()
        MidgarLog.notice("Trakt invitation put away", category: .trakt)
        focusAfterTraktInvite = itemAfterTraktInvite
        refreshCommunity()
    }

    /// The first thing under the invitation that takes focus: More Like This, else Information, else the last of the cast.
    private var itemAfterTraktInvite: Item? {
        guard let content else { return nil }
        if let related = content.related.first { return .related(related.id) }
        if !content.facts.isEmpty { return .information }
        return content.cast.last.map { .person($0.id) }
    }
}
