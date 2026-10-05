import UIKit

final class MovieGridViewController: LibraryGridViewController {
    init(api: APIClient, sectionId: String) {
        super.init(api: api, sectionId: sectionId, kind: .movie)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
