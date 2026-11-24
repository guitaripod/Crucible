import CrucibleCore
import CrucibleDesign
import UIKit

/// Marking a title incompatible from the Apple TV's title page, which leaves it out of Home, search and the libraries on
/// every device of the server, and putting it back.
@MainActor
enum TVIncompatibleAction {
    static func button(for item: PlexMetadata, env: TVAppEnvironment, host: UIViewController, reload: @escaping @MainActor () -> Void) -> TVDetailAction {
        let marked = IncompatibleTitles.hides(item)
        return TVDetailAction(
            kind: .incompatible,
            title: marked ? IncompatibleCopy.unmark : IncompatibleCopy.mark,
            symbol: marked ? "eye" : "eye.slash",
            handler: { [weak host] in
                guard let host else { return }
                Haptics.light()
                Task {
                    if marked, let mark = IncompatibleTitles.marks.first(where: { $0.ratingKey == item.id }) {
                        do {
                            try await IncompatibleTitles.unmark(mark, api: env.api)
                        } catch {
                            Haptics.error()
                            return
                        }
                    } else {
                        await IncompatibleTitles.markManually(item, api: env.api)
                    }
                    reload()
                }
            }
        )
    }
}
