import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The server owner's tools in a title's and a library's menus. Nobody else sees them: the server would refuse them anyway.
@MainActor
enum ManageMenus {
    /// Refresh, analyze, fix the match, edit the details, pick artwork or delete a title.
    static func itemMenu(for item: PlexMetadata, api: APIClient, host: UIViewController, reload: @escaping @MainActor () -> Void) -> UIMenu? {
        guard ServerOwnership.isOwner(), ["movie", "show", "season", "episode"].contains(item.mediaType) else { return nil }
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
                let picker = FixMatchViewController(item: item, api: api, onMatched: reload)
                host.present(UINavigationController(rootViewController: picker), animated: true)
            })
            actions.append(UIAction(title: ManageCopy.unmatch, image: UIImage(systemName: "minus.circle")) { _ in
                run(host: host, reloadAfter: .seconds(2), reload: reload) { try await LibraryManagement.unmatch(ratingKey: key, api: api) }
            })
        }
        if item.mediaType == "show" {
            actions.append(UIAction(title: ManageCopy.showSettings, image: UIImage(systemName: "slider.horizontal.3")) { _ in
                host.present(UINavigationController(rootViewController: ShowSettingsViewController(ratingKey: key, api: api)), animated: true)
            })
        }
        if let section = item.librarySectionID.map(String.init) {
            actions.append(UIAction(title: ManageCopy.editDetails, image: UIImage(systemName: "pencil")) { _ in
                let editor = EditDetailsViewController(edit: MetadataEdit(item: item, sectionId: section), api: api, onSaved: reload)
                host.present(UINavigationController(rootViewController: editor), animated: true)
            })
        }
        actions.append(contentsOf: [ArtworkKind.poster, .background].map { kind in
            UIAction(title: kind.chooseTitle, image: UIImage(systemName: kind == .poster ? "photo.on.rectangle" : "photo")) { _ in
                let picker = ArtworkPickerViewController(ratingKey: key, kind: kind, api: api, onChosen: reload)
                host.present(UINavigationController(rootViewController: picker), animated: true)
            }
        })
        let delete = UIAction(title: ManageCopy.delete, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            confirmDelete(item, api: api, host: host)
        }
        return UIMenu(title: ManageCopy.menuTitle, image: UIImage(systemName: "wrench.and.screwdriver"), children: [
            UIMenu(options: .displayInline, children: actions),
            UIMenu(options: .displayInline, children: [delete]),
        ])
    }

    /// Scan, refresh, analyze and empty the trash of a library.
    static func libraryMenu(sectionId: String, api: APIClient, host: UIViewController) -> UIMenu? {
        guard ServerOwnership.isOwner() else { return nil }
        return UIMenu(title: ManageCopy.menuTitle, image: UIImage(systemName: "wrench.and.screwdriver"), children: [
            UIAction(title: ManageCopy.scanLibrary, image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in
                run(host: host) { try await LibraryManagement.scan(sectionId: sectionId, force: false, api: api) }
            },
            UIAction(title: ManageCopy.refreshLibrary, image: UIImage(systemName: "arrow.clockwise")) { _ in
                confirm(title: ManageCopy.refreshLibrary, message: ManageCopy.refreshLibraryMessage, action: ManageCopy.refreshLibrary, host: host) {
                    run(host: host) { try await LibraryManagement.scan(sectionId: sectionId, force: true, api: api) }
                }
            },
            UIAction(title: ManageCopy.analyzeLibrary, image: UIImage(systemName: "waveform.badge.magnifyingglass")) { _ in
                run(host: host) { try await LibraryManagement.analyze(sectionId: sectionId, api: api) }
            },
            UIAction(title: ManageCopy.emptyTrash, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                confirm(title: ManageCopy.emptyTrash, message: ManageCopy.emptyTrashMessage, action: ManageCopy.emptyTrash, host: host) {
                    run(host: host) { try await LibraryManagement.emptyTrash(sectionId: sectionId, api: api) }
                }
            },
        ])
    }

    /// Sends a tool to the server: a haptic says it went, an alert says when the server refused it, and the screen
    /// reloads once the server has had a moment to do it.
    static func run(
        host: UIViewController,
        reloadAfter delay: Duration? = nil,
        reload: (@MainActor () -> Void)? = nil,
        _ work: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor [weak host] in
            do {
                try await work()
                Haptics.success()
                if let delay, let reload {
                    try? await Task.sleep(for: delay)
                    reload()
                }
            } catch {
                Haptics.error()
                let alert = UIAlertController(title: ManageCopy.failed, message: ConnectionError.message(for: error), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                host?.present(alert, animated: true)
            }
        }
    }

    static func confirm(title: String, message: String, action: String, host: UIViewController, then: @escaping @MainActor () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in then() })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        host.present(alert, animated: true)
    }

    private static func confirmDelete(_ item: PlexMetadata, api: APIClient, host: UIViewController) {
        confirm(title: ManageCopy.delete, message: ManageCopy.deleteMessage(item.title), action: String(localized: "Delete", comment: "Button that confirms deleting a title from the server"), host: host) {
            run(host: host) {
                try await LibraryManagement.delete(ratingKey: item.id, api: api)
                host.navigationController?.popViewController(animated: true)
            }
        }
    }
}
