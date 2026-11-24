import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The title menu's way into `IncompatibleTitles`: mark this title as one the app cannot play here, so it leaves Home,
/// search and the libraries on every device of the server, or put it back if it is already marked.
@MainActor
enum IncompatibleMenuAction {
    static func action(
        for item: PlexMetadata,
        api: APIClient,
        host: UIViewController,
        refresh: @escaping @MainActor () -> Void
    ) -> UIAction {
        guard IncompatibleTitles.hides(item) else {
            return UIAction(title: IncompatibleCopy.mark, image: UIImage(systemName: "eye.slash")) { [weak host] _ in
                guard let host else { return }
                Haptics.light()
                Task {
                    await IncompatibleTitles.markManually(item, api: api)
                    refresh()
                    leavePage(host, hidden: IncompatibleTitles.isShared(item.id))
                }
            }
        }
        return UIAction(title: IncompatibleCopy.unmark, image: UIImage(systemName: "eye")) { [weak host] _ in
            guard let host, let mark = IncompatibleTitles.marks.first(where: { $0.ratingKey == item.id }) else { return }
            Task {
                do {
                    try await IncompatibleTitles.unmark(mark, api: api)
                    Haptics.light()
                    refresh()
                } catch {
                    Haptics.error()
                    presentFailure(error, on: host)
                }
            }
        }
    }

    /// A title just marked is gone from the app, so its own page goes back to what it was opened from rather than
    /// sitting there as a title that no longer exists anywhere else.
    private static func leavePage(_ host: UIViewController, hidden: Bool) {
        guard hidden else {
            presentFailure(nil, on: host, message: IncompatibleCopy.hiddenHereOnly)
            return
        }
        host.navigationController?.popViewController(animated: true)
    }

    private static func presentFailure(_ error: Error?, on host: UIViewController, message: String? = nil) {
        let alert = UIAlertController(
            title: IncompatibleCopy.mark,
            message: message ?? error.map { ConnectionError.message(for: $0) } ?? IncompatibleCopy.hiddenHereOnly,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        host.present(alert, animated: true)
    }
}
