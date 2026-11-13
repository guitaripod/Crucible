import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// What to Watch on iPhone and iPad: a sentence about what the person feels like, then picks from their own library,
/// each with a reason. It says what is sent before anything is, and nothing is sent until they ask.
final class WhatToWatchViewController: UIViewController, UICollectionViewDelegate, UITextFieldDelegate {
    private enum Phase {
        case asking
        case working(WatchStep)
        case answered(WatchAnswer)
        case failed(WatchFailure)
    }

    private enum Section: Hashable {
        case picks
    }

    private let api: APIClient
    private let session: WatchSession
    private let field = UITextField()
    private let examples = UIStackView()
    private let explanationLabel = UILabel()
    private let statusRow = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let failureLabel = UILabel()
    private let noteLabel = UILabel()
    private let header = UIStackView()
    private lazy var suggestButton = Self.button(WatchCopy.suggest, filled: true) { [weak self] in self?.suggest() }
    private lazy var retryButton = Self.button(WatchCopy.tryAgain, filled: false) { [weak self] in self?.suggest() }
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>?
    private var work: Task<Void, Never>?
    private var phase: Phase = .asking {
        didSet { render() }
    }

    init(api: APIClient) {
        self.api = api
        self.session = WatchSession(api: api)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = WatchCopy.title
        view.backgroundColor = Theme.Color.canvas
        navigationItem.largeTitleDisplayMode = .never
        buildHeader()
        buildList()
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .asking = phase, request.isEmpty { field.becomeFirstResponder() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { work?.cancel() }
    }

    private var request: String {
        WatchPicker.cleaned(field.text ?? "")
    }

    private func buildHeader() {
        field.placeholder = WatchCopy.placeholder
        field.font = Theme.Font.body
        field.adjustsFontForContentSizeCategory = true
        field.textColor = Theme.Color.label
        field.backgroundColor = Theme.Color.surface
        field.layer.cornerRadius = Theme.Radius.s
        field.layer.cornerCurve = .continuous
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .go
        field.enablesReturnKeyAutomatically = true
        field.delegate = self
        field.accessibilityIdentifier = "watch.field"
        field.accessibilityLabel = WatchCopy.title
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget).isActive = true
        field.addAction(UIAction { [weak self] _ in self?.updateSuggestButton() }, for: .editingChanged)
        suggestButton.accessibilityIdentifier = "watch.suggest"
        suggestButton.setContentHuggingPriority(.required, for: .horizontal)
        suggestButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let ask = UIStackView(arrangedSubviews: [field, suggestButton])
        ask.axis = .horizontal
        ask.spacing = Theme.Space.xs
        ask.alignment = .center

        examples.axis = .vertical
        examples.spacing = Theme.Space.xs
        examples.alignment = .leading
        for example in WatchCopy.examples {
            examples.addArrangedSubview(Self.button(example, filled: false) { [weak self] in
                self?.field.text = example
                self?.updateSuggestButton()
                self?.suggest()
            })
        }

        Self.style(explanationLabel, font: Theme.Font.footnote, color: Theme.Color.labelSecondary)
        explanationLabel.text = WatchCopy.explanation
        Self.style(statusLabel, font: Theme.Font.subheadline, color: Theme.Color.labelSecondary)
        statusLabel.accessibilityIdentifier = "watch.status"
        spinner.startAnimating()
        statusRow.axis = .horizontal
        statusRow.spacing = Theme.Space.xs
        statusRow.alignment = .center
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        Self.style(failureLabel, font: Theme.Font.callout, color: Theme.Color.label)
        failureLabel.accessibilityIdentifier = "watch.failure"
        Self.style(noteLabel, font: Theme.Font.footnote, color: Theme.Color.labelSecondary)

        let retryRow = UIStackView(arrangedSubviews: [retryButton, UIView()])
        retryRow.axis = .horizontal
        [ask, statusRow, failureLabel, retryRow, examples, explanationLabel, noteLabel].forEach(header.addArrangedSubview)
        header.axis = .vertical
        header.spacing = Theme.Space.m
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.s, leading: Theme.Space.l, bottom: Theme.Space.s, trailing: Theme.Space.l)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor, constant: -Theme.Space.l),
            header.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor, constant: Theme.Space.l),
        ])
    }

    private func buildList() {
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor, constant: -Theme.Space.l),
            collectionView.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor, constant: Theme.Space.l),
            collectionView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, case .answered(let answer) = self.phase, let pick = answer.picks.first(where: { $0.id == id }) else { return }
            var content = WatchPickConfiguration()
            content.posterPath = answer.item(for: pick)?.thumb
            content.title = pick.title.title
            content.facts = WatchCopy.facts(pick.title)
            content.why = pick.why
            content.placeholderIcon = pick.title.kind == .show ? "tv" : "film"
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "watch.pick.\(id)"
            var background = UIBackgroundConfiguration.listPlainCell()
            background.backgroundColor = .clear
            cell.backgroundConfiguration = background
        }
        dataSource = UICollectionViewDiffableDataSource<Section, String>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    private static func layout() -> UICollectionViewLayout {
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: list)
    }

    private func render() {
        guard isViewLoaded else { return }
        var isAsking = false
        var step: WatchStep?
        var answer: WatchAnswer?
        var failure: WatchFailure?
        switch phase {
        case .asking: isAsking = true
        case .working(let current): step = current
        case .answered(let made): answer = made
        case .failed(let reason): failure = reason
        }
        statusRow.isHidden = step == nil
        statusLabel.text = step.map(WatchCopy.step)
        failureLabel.isHidden = failure == nil
        failureLabel.text = failure.map(WatchCopy.failure)
        retryButton.superview?.isHidden = !(failure.map(WatchCopy.canRetry) ?? false)
        examples.isHidden = !(isAsking || failure != nil)
        explanationLabel.isHidden = answer != nil || step != nil
        noteLabel.isHidden = answer?.note.isEmpty ?? true
        noteLabel.text = answer?.note
        field.isEnabled = step == nil
        updateSuggestButton()

        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.picks])
        snapshot.appendItems(answer?.picks.map(\.id) ?? [])
        dataSource?.applySnapshotUsingReloadData(snapshot)
        if let failure {
            UIAccessibility.post(notification: .layoutChanged, argument: failureLabel)
            MidgarLog.notice("What to Watch showed a failure: \(failure)", category: .lifecycle)
        } else if answer != nil {
            UIAccessibility.post(notification: .screenChanged, argument: collectionView)
        }
    }

    private func updateSuggestButton() {
        var isWorking = false
        if case .working = phase { isWorking = true }
        suggestButton.isEnabled = !isWorking && !request.isEmpty
    }

    /// Asks for picks once the person may: What to Watch is part of Crucible Pro and of a Pro Week.
    private func suggest() {
        let request = request
        guard !request.isEmpty else { return }
        if case .working = phase { return }
        field.resignFirstResponder()
        ProAccess.shared.requestUnlock(.whatToWatch) { [weak self] unlocked in
            guard unlocked, let self else { return }
            self.run(request)
        }
    }

    private func run(_ request: String) {
        Haptics.selection()
        work?.cancel()
        phase = .working(.readingLibrary)
        let progress: @Sendable (WatchStep) -> Void = { [weak self] step in
            Task { @MainActor [weak self] in
                guard let self, case .working = self.phase else { return }
                self.phase = .working(step)
            }
        }
        work = Task { [weak self, session] in
            let result = await session.answer(request, progress: progress)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let answer):
                Haptics.success()
                self.phase = .answered(answer)
            case .failure(let failure):
                Haptics.error()
                self.phase = .failed(failure)
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        suggest()
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .answered(let answer) = phase, answer.picks.indices.contains(indexPath.item) else { return }
        let pick = answer.picks[indexPath.item]
        switch pick.title.kind {
        case .movie: navigationController?.pushViewController(MediaDetailViewController(api: api, ratingKey: pick.id, mediaType: "movie"), animated: true)
        case .show: navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: pick.id), animated: true)
        }
    }

    private static func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.title = title
        if filled {
            configuration.baseBackgroundColor = Theme.Color.accent
            configuration.baseForegroundColor = .black
        } else {
            configuration.baseForegroundColor = Theme.Color.label
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }

    private static func style(_ label: UILabel, font: UIFont, color: UIColor) {
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
    }
}
