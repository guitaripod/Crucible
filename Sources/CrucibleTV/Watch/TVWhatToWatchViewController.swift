import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// The picks for one What to Watch request on Apple TV: two columns of tiles, each with its reason, under the request
/// itself. The screen asks once when it opens; coming back from a pick's page shows the same picks again.
final class TVWhatToWatchViewController: TVScreenViewController {
    private let env: TVAppEnvironment
    private let request: String
    private let session: WatchSession
    private var answer: WatchAnswer?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var askSlot = makeTaskSlot()

    init(env: TVAppEnvironment, request: String) {
        self.env = env
        self.request = WatchPicker.cleaned(request)
        session = WatchSession(api: env.api)
        super.init(layout: UICollectionViewLayout())
        title = WatchCopy.title
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, _ in
            let section = TVShelf.grid(columns: 2, itemHeight: TVWatchPickSurface.height, header: false)
            section.boundarySupplementaryItems = [TVScreenTitleView.headerItem()]
            return section
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        ask()
    }

    private func configureDataSource() {
        let tile = TVHostCell.registration { [weak self] (id: String) -> UIView in
            guard let self, let answer, let pick = answer.picks.first(where: { $0.id == id }) else { return UIView() }
            let surface = TVWatchPickSurface(pick: pick, artworkPath: answer.item(for: pick)?.thumb)
            surface.accessibilityIdentifier = "watch.pick.\(id)"
            surface.addAction(UIAction { [weak self] _ in self?.open(pick) }, for: .primaryActionTriggered)
            return surface
        }
        let header = TVScreenTitleView.headerRegistration { [weak self] _ in
            guard let self else { return nil }
            return TVScreenTitleContent(title: WatchCopy.title, summary: request, detail: answer?.note.isEmpty == false ? answer?.note : nil)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: tile, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        adopt(dataSource)
    }

    private func ask() {
        show(state: .loading(title: WatchCopy.step(.readingLibrary)))
        askSlot.run { [weak self] in
            guard let self else { return }
            let progress: @Sendable (WatchStep) -> Void = { [weak self] step in
                Task { @MainActor [weak self] in
                    guard let self, self.answer == nil, self.isShowingState else { return }
                    self.show(state: .loading(title: WatchCopy.step(step)))
                }
            }
            let result = await session.answer(request, progress: progress)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let answer): display(answer)
            case .failure(let failure): display(failure)
            }
        }
    }

    private func display(_ answer: WatchAnswer) {
        self.answer = answer
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(answer.picks.map(\.id), toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
        showContent()
    }

    private func display(_ failure: WatchFailure) {
        MidgarLog.notice("What to Watch showed a failure: \(failure)", category: .lifecycle)
        let back = TVStateView.Action(title: String(localized: "Back")) { [weak self] in
            guard let self else { return }
            TVNavigation.pop(from: self)
        }
        guard WatchCopy.canRetry(failure) else {
            show(state: .empty(title: WatchCopy.title, message: WatchCopy.failure(failure), symbol: "wand.and.stars", action: back))
            return
        }
        show(state: .error(title: WatchCopy.title, message: WatchCopy.failure(failure), retryTitle: WatchCopy.tryAgain, retry: { [weak self] in self?.ask() }, secondary: back))
    }

    private func open(_ pick: WatchPick) {
        let destination: UIViewController
        switch pick.title.kind {
        case .movie: destination = TVScreens.movieDetail(env, ratingKey: pick.id, mediaType: "movie")
        case .show: destination = TVScreens.showDetail(env, ratingKey: pick.id, initialSeasonKey: nil)
        }
        TVNavigation.push(destination, from: self)
    }
}

/// Asking What to Watch on Apple TV: what is sent, the examples one press away, and a sentence of the person's own,
/// dictated or typed. Asking is part of Crucible Pro and of a Pro Week; the picks open over this screen, so Menu
/// comes back here to ask for something else.
final class TVWhatToWatchAskViewController: UIViewController {
    private let env: TVAppEnvironment
    private var buttons: [UIButton] = []

    init(env: TVAppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
        title = WatchCopy.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        let heading = UILabel()
        heading.text = WatchCopy.title
        heading.font = Theme.Font.title2
        heading.textColor = Theme.Color.label
        heading.accessibilityTraits = .header
        let explanation = UILabel()
        explanation.text = WatchCopy.explanation
        explanation.font = Theme.Font.body
        explanation.textColor = Theme.Color.labelSecondary
        explanation.numberOfLines = 0

        buttons = WatchCopy.examples.enumerated().map { place, example in
            let button = TVButton.make(.glass, title: example) { [weak self] in self?.ask(example) }
            button.accessibilityIdentifier = "watch.example.\(place)"
            return button
        }
        let own = TVButton.make(.glass, title: WatchCopy.typeYourOwn, symbol: "mic") { [weak self] in self?.presentField() }
        own.accessibilityIdentifier = "watch.own"
        buttons.append(own)
        let choices = UIStackView(arrangedSubviews: buttons)
        choices.axis = .vertical
        choices.alignment = .leading
        choices.spacing = Theme.Space.s

        let stack = UIStackView(arrangedSubviews: [heading, explanation, choices])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.l
        stack.setCustomSpacing(Theme.Space.s, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.xl),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Space.xl),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        buttons.first.map { [$0] } ?? []
    }

    /// Takes a sentence through the system keyboard, which also takes dictation from the remote.
    private func presentField() {
        guard presentedViewController == nil else { return }
        let entry = UIAlertController(title: WatchCopy.title, message: nil, preferredStyle: .alert)
        entry.addTextField { field in
            field.placeholder = WatchCopy.placeholder
            field.autocapitalizationType = .sentences
            field.returnKeyType = .done
            field.accessibilityIdentifier = "watch.field"
        }
        entry.addAction(UIAlertAction(title: WatchCopy.suggest, style: .default) { [weak self, weak entry] _ in
            guard let request = entry?.textFields?.first?.text, !WatchPicker.cleaned(request).isEmpty else { return }
            self?.askOnceUncovered(request)
        })
        entry.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(entry, animated: TVMotion.animationsEnabled)
    }

    /// Asks once the alert that took the sentence has left the screen: a push under an alert is refused, and the
    /// alert is still closing when its button's action runs.
    private func askOnceUncovered(_ request: String) {
        guard let alert = presentedViewController else { return ask(request) }
        guard let closing = alert.transitionCoordinator else {
            DispatchQueue.main.async { [weak self] in self?.askOnceUncovered(request) }
            return
        }
        closing.animate(alongsideTransition: nil) { [weak self] _ in self?.ask(request) }
    }

    private func ask(_ request: String) {
        ProAccess.shared.requestUnlock(.whatToWatch) { [weak self] unlocked in
            guard unlocked, let self else { return }
            TVNavigation.push(TVScreens.whatToWatch(env, request: request), from: self)
        }
    }
}
