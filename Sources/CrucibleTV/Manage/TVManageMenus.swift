import CrucibleCore
import CrucibleDesign
import UIKit

/// The server owner's tools on Apple TV, the same ones the iPhone offers: a title's Manage menu (refresh, analyze, Fix Match,
/// Edit Details, the poster and background pickers, delete) and a library's (scan, refresh, analyze, empty the trash). Nobody
/// else sees them: the server would refuse them anyway.
@MainActor
enum TVManageMenus {
    /// `leavesScreenWhenDeleted` is for a title's own screen, which has nothing left to show once the title is gone; a list
    /// just reloads.
    static func itemMenu(
        for item: PlexMetadata,
        env: TVAppEnvironment,
        host: UIViewController,
        leavesScreenWhenDeleted: Bool = false,
        reload: @escaping @MainActor () -> Void
    ) -> UIMenu? {
        guard ServerOwnership.isOwner(), ["movie", "show", "season", "episode"].contains(item.mediaType) else { return nil }
        let api = env.api
        let key = item.id
        var actions: [UIMenuElement] = [
            UIAction(title: ManageCopy.refreshMetadata, image: UIImage(systemName: "arrow.clockwise")) { _ in
                run(host: host, reloadAfter: .seconds(3), reload: reload) { try await LibraryManagement.refresh(ratingKey: key, api: api) }
            },
            UIAction(title: ManageCopy.analyze, image: UIImage(systemName: "waveform.badge.magnifyingglass")) { _ in
                run(host: host, reloadAfter: .seconds(3), reload: reload) { try await LibraryManagement.analyze(ratingKey: key, api: api) }
            },
        ]
        if item.mediaType == "movie" || item.mediaType == "show" {
            actions.append(UIAction(title: ManageCopy.fixMatch, image: UIImage(systemName: "link")) { _ in
                TVNavigation.push(TVFixMatchViewController(item: item, api: api, onMatched: reload), from: host)
            })
            actions.append(UIAction(title: ManageCopy.unmatch, image: UIImage(systemName: "minus.circle")) { _ in
                run(host: host, reloadAfter: .seconds(2), reload: reload) { try await LibraryManagement.unmatch(ratingKey: key, api: api) }
            })
        }
        if let section = item.librarySectionID.map(String.init) {
            actions.append(UIAction(title: ManageCopy.editDetails, image: UIImage(systemName: "pencil")) { _ in
                TVNavigation.push(TVEditDetailsViewController(edit: MetadataEdit(item: item, sectionId: section), api: api, onSaved: reload), from: host)
            })
        }
        actions.append(contentsOf: [ArtworkKind.poster, .background].map { kind in
            UIAction(title: kind.chooseTitle, image: UIImage(systemName: kind == .poster ? "photo.on.rectangle" : "photo")) { _ in
                TVNavigation.push(artworkPicker(ratingKey: key, kind: kind, api: api, onChosen: reload), from: host)
            }
        })
        let delete = UIAction(title: ManageCopy.delete, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            host.presentConfirmation(
                title: ManageCopy.delete,
                message: ManageCopy.deleteMessage(item.title),
                confirmTitle: String(localized: "Delete", comment: "Button that confirms deleting a title from the server")
            ) {
                if leavesScreenWhenDeleted {
                    Task { @MainActor [weak host] in
                        do {
                            try await LibraryManagement.delete(ratingKey: key, api: api)
                            if let host { TVNavigation.pop(from: host) }
                        } catch {
                            host?.presentAlert(title: ManageCopy.failed, message: ConnectionError.message(for: error))
                        }
                    }
                } else {
                    run(host: host, reloadAfter: .zero, reload: reload) { try await LibraryManagement.delete(ratingKey: key, api: api) }
                }
            }
        }
        return UIMenu(title: ManageCopy.menuTitle, image: UIImage(systemName: "wrench.and.screwdriver"), children: [
            UIMenu(options: .displayInline, children: actions),
            UIMenu(options: .displayInline, children: [delete]),
        ])
    }

    /// Scan, refresh, analyze and empty the trash of a library.
    static func libraryMenu(sectionId: String, env: TVAppEnvironment, host: UIViewController) -> UIMenu? {
        guard ServerOwnership.isOwner() else { return nil }
        let api = env.api
        return UIMenu(title: ManageCopy.menuTitle, image: UIImage(systemName: "wrench.and.screwdriver"), children: [
            UIAction(title: ManageCopy.scanLibrary, image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in
                run(host: host) { try await LibraryManagement.scan(sectionId: sectionId, force: false, api: api) }
            },
            UIAction(title: ManageCopy.refreshLibrary, image: UIImage(systemName: "arrow.clockwise")) { _ in
                host.presentConfirmation(title: ManageCopy.refreshLibrary, message: ManageCopy.refreshLibraryMessage, confirmTitle: ManageCopy.refreshLibrary) {
                    run(host: host) { try await LibraryManagement.scan(sectionId: sectionId, force: true, api: api) }
                }
            },
            UIAction(title: ManageCopy.analyzeLibrary, image: UIImage(systemName: "waveform.badge.magnifyingglass")) { _ in
                run(host: host) { try await LibraryManagement.analyze(sectionId: sectionId, api: api) }
            },
            UIAction(title: ManageCopy.emptyTrash, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                host.presentConfirmation(title: ManageCopy.emptyTrash, message: ManageCopy.emptyTrashMessage, confirmTitle: ManageCopy.emptyTrash) {
                    run(host: host) { try await LibraryManagement.emptyTrash(sectionId: sectionId, api: api) }
                }
            },
        ])
    }

    /// The poster or background picker: every picture the server's agents and the owner's uploads offer, with the one in use
    /// marked. Picking one makes it the title's artwork and goes back.
    static func artworkPicker(ratingKey: String, kind: ArtworkKind, api: APIClient, onChosen: @escaping @MainActor () -> Void) -> UIViewController {
        var choices = [String: PlexArtworkChoice]()
        let inUse = String(localized: "In Use", comment: "Caption of the artwork a title uses now")
        let grid = TVMediaGridViewController(
            title: kind == .poster
                ? String(localized: "Choose Poster", comment: "Title of the poster picker")
                : String(localized: "Choose Background", comment: "Title of the background picker"),
            empty: .init(symbol: "photo", title: String(localized: "Nothing to Choose From", comment: "Artwork picker empty state"), message: ""),
            style: kind == .poster ? .poster : .landscape,
            card: { media in
                TVCardItem(id: media.entryID, artworkPath: media.thumb, title: media.title, placeholderSymbol: "photo")
            },
            load: {
                let loaded = try await LibraryManagement.artwork(ratingKey: ratingKey, kind: kind, api: api)
                choices = Dictionary(loaded.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first })
                return loaded.compactMap { choice in
                    let fields: [String: Any] = [
                        "ratingKey": choice.ratingKey,
                        "type": "photo",
                        "title": choice.selected == true ? inUse : (choice.provider ?? ""),
                        "thumb": choice.imagePath ?? "",
                    ]
                    return (try? JSONSerialization.data(withJSONObject: fields)).flatMap { try? JSONDecoder().decode(PlexMetadata.self, from: $0) }
                }
            }
        )
        grid.summary = { _ in nil }
        grid.onSelect = { [weak grid] media in
            guard let grid, let choice = choices[media.id], choice.selected != true else { return }
            Task { @MainActor [weak grid] in
                do {
                    try await LibraryManagement.select(choice, kind: kind, ratingKey: ratingKey, api: api)
                    if let grid { TVNavigation.pop(from: grid) }
                    onChosen()
                } catch {
                    grid?.presentAlert(title: ManageCopy.failed, message: ConnectionError.message(for: error))
                }
            }
        }
        return grid
    }

    /// Sends a tool to the server: an alert says it went, or that the server refused it, and the screen reloads once the
    /// server has had a moment to do it.
    static func run(
        host: UIViewController,
        reloadAfter delay: Duration? = nil,
        reload: (@MainActor () -> Void)? = nil,
        _ work: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor [weak host] in
            do {
                try await work()
                host?.presentAlert(title: ManageCopy.done)
                if let delay, let reload {
                    try? await Task.sleep(for: delay)
                    reload()
                }
            } catch {
                host?.presentAlert(title: ManageCopy.failed, message: ConnectionError.message(for: error))
            }
        }
    }
}
