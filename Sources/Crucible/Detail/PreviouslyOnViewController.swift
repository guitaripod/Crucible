import CrucibleCore
import CrucibleDesign
import UIKit

/// The Previously On a paired Crucible Server writes for a show: a short read of the episodes watched so far, what it
/// draws on, and the computer that wrote it.
final class PreviouslyOnViewController: UIViewController {
    private let model: ShowDetailModel
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let basisLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var task: Task<Void, Never>?

    init(model: ShowDetailModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Presents the recap as a sheet over `host`.
    static func present(for model: ShowDetailModel, from host: UIViewController) {
        let screen = PreviouslyOnViewController(model: model)
        let navigation = UINavigationController(rootViewController: screen)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        titleLabel.text = CompanionCopy.previouslyOnTitle(model.show.title)
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.font = Theme.Font.body
        bodyLabel.textColor = Theme.Color.label
        bodyLabel.numberOfLines = 0
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.text = CompanionCopy.writing
        bodyLabel.accessibilityIdentifier = "previouslyOn.text"
        basisLabel.font = Theme.Font.footnote
        basisLabel.textColor = Theme.Color.labelSecondary
        basisLabel.numberOfLines = 0
        basisLabel.adjustsFontForContentSizeCategory = true
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [titleLabel, spinner, bodyLabel, basisLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.m
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.s),
            stack.leadingAnchor.constraint(equalTo: scroll.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.readableContentGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.l),
        ])
        load()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { task?.cancel() }
    }

    private func load() {
        task = Task { [weak self] in
            guard let self else { return }
            do throws(CompanionError) {
                let (recap, server) = try await PreviouslyOnRequest.recap(model)
                bodyLabel.text = recap.text
                basisLabel.text = CompanionCopy.basis(recap, server: server)
            } catch {
                bodyLabel.text = error.message
            }
            spinner.stopAnimating()
            spinner.isHidden = true
            UIAccessibility.post(notification: .layoutChanged, argument: bodyLabel)
        }
    }
}
