import UIKit

/// Server & Connection screen: the active server, every known route with its latency, and the
/// connection preferences.
final class ServerDetailViewController: UIViewController {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Server"
        view.backgroundColor = Theme.Color.canvas
    }
}
