import UIKit

final class ShowGridViewController: LibraryGridViewController {
    init(api: APIClient, sectionId: String) {
        super.init(api: api, sectionId: sectionId, kind: .show)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
