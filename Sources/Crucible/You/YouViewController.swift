import UIKit

final class YouViewController: UICollectionViewController {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "You"
        navigationController?.navigationBar.prefersLargeTitles = true
        view.backgroundColor = Theme.Color.canvas
    }
}
