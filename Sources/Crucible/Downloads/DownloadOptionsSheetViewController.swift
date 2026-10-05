import UIKit

/// Bottom sheet for downloading part of a show: which episodes, at what quality, and whether to keep
/// the next few downloaded automatically.
final class DownloadOptionsSheetViewController: UIViewController {
    struct Context {
        let showRatingKey: String
        let showTitle: String
        let seasonTitle: String
        let posterPath: String?
        let episodes: [PlexMetadata]
    }

    private let context: Context
    private let onFinish: () -> Void

    init(context: Context, onFinish: @escaping () -> Void) {
        self.context = context
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
    }
}
