import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// What to Watch on iPhone and iPad: a sentence about what the person feels like, then picks from their own library,
/// each with a reason. It says what is sent before anything is, and nothing is sent until they ask. In the demo
/// there is no field: its example requests are the ones that have an answer, and the one asked stays marked.
///
/// A viewer without Crucible Pro gets one real answer (`ProTasteStore`): the first pick as it is, and the others
/// sealed, showing why each was chosen but not what it is, until Pro is on.
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

    /// A row of the answer: a pick that can be opened, the line and button between it and the sealed ones, or a pick
    /// whose title and poster wait for Crucible Pro.
    private enum Row: Hashable {
        case pick(String)
        case seal
        case sealedPick(String)
    }

    private let api: APIClient
    private let session: WatchSession
    private let answersExamplesOnly = !HostedBrain.takesAnyRequest
    private var exampleButtons: [UIButton] = []
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
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>?
    private var work: Task<Void, Never>?
    /// The answer on screen was given as a taste, so all but its first pick stay sealed until Crucible Pro is on.
    private var answerIsTaste = false
    private lazy var proObservation = ProObservation { [weak self] in self?.unsealIfProArrived() }
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
        _ = proObservation
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .asking = phase, request.isEmpty, !answersExamplesOnly { field.becomeFirstResponder() }
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
        ask.isHidden = answersExamplesOnly

        examples.axis = .vertical
        examples.spacing = Theme.Space.xs
        examples.alignment = .leading
        exampleButtons = WatchCopy.examples.enumerated().map { place, example in
            let button = Self.button(example, filled: false) { [weak self] in
                self?.field.text = example
                self?.updateSuggestButton()
                self?.suggest()
            }
            button.accessibilityIdentifier = "watch.example.\(place)"
            button.configurationUpdateHandler = { button in
                button.configuration = Self.capsule(example, filled: button.isSelected)
            }
            return button
        }
        exampleButtons.forEach(examples.addArrangedSubview)

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
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self, case .answered(let answer) = self.phase else { return }
            var background = UIBackgroundConfiguration.listPlainCell()
            background.backgroundColor = .clear
            cell.backgroundConfiguration = background
            switch row {
            case .pick(let id):
                guard let pick = answer.picks.first(where: { $0.id == id }) else { return }
                cell.contentConfiguration = Self.content(for: pick, posterPath: answer.item(for: pick)?.thumb)
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "watch.pick.\(id)"
            case .sealedPick(let id):
                guard let pick = answer.picks.first(where: { $0.id == id }) else { return }
                cell.contentConfiguration = Self.sealedContent(for: pick)
                cell.accessories = []
                cell.accessibilityIdentifier = "watch.sealed.\(id)"
            case .seal:
                cell.contentConfiguration = WatchSealConfiguration(note: WatchCopy.sealedNote, action: WatchCopy.seeEveryPick) { [weak self] in
                    self?.unseal()
                }
                cell.accessories = []
                cell.accessibilityIdentifier = "watch.seal"
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
    }

    private static func content(for pick: WatchPick, posterPath: String?) -> WatchPickConfiguration {
        var content = WatchPickConfiguration()
        content.posterPath = posterPath
        content.title = pick.title.title
        content.facts = WatchCopy.facts(pick.title)
        content.why = pick.why
        content.placeholderIcon = pick.title.kind == .show ? "tv" : "film"
        return content
    }

    /// A sealed pick says why it was chosen and nothing that names it: no title, no poster, no year or length.
    private static func sealedContent(for pick: WatchPick) -> WatchPickConfiguration {
        var content = WatchPickConfiguration()
        content.title = WatchCopy.sealedTitle
        content.why = pick.why
        content.placeholderIcon = ProLock.symbolName
        content.isSealed = true
        return content
    }

    /// The rows of an answer: every pick, or for a taste the first pick, the line that says what the rest are, and the
    /// rest sealed. An answer of one pick has nothing to seal.
    private func rows(for answer: WatchAnswer) -> [Row] {
        guard sealsAnswer, answer.picks.count > 1 else { return answer.picks.map { .pick($0.id) } }
        return [.pick(answer.picks[0].id), .seal] + answer.picks.dropFirst().map { .sealedPick($0.id) }
    }

    private var sealsAnswer: Bool { answerIsTaste && !ProAccess.shared.hasFullAccess }

    /// Opens the paywall from the sealed part of an answer; once Crucible Pro is on, the picks open where they stand.
    private func unseal() {
        ProAccess.shared.requestUnlock(.whatToWatch) { [weak self] unlocked in
            if unlocked { self?.openSealedPicks() }
        }
    }

    /// Pro can also arrive while a sealed answer is on screen without this screen asking: a purchase made elsewhere, or
    /// a Pro Week that starts.
    private func unsealIfProArrived() {
        if ProAccess.shared.hasFullAccess { openSealedPicks() }
    }

    private func openSealedPicks() {
        guard answerIsTaste, case .answered = phase else { return }
        answerIsTaste = false
        render()
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
        examples.isHidden = !(answersExamplesOnly || isAsking || failure != nil)
        for (button, example) in zip(exampleButtons, WatchCopy.examples) {
            button.isSelected = answersExamplesOnly && !isAsking && WatchPicker.cleaned(example) == request
        }
        explanationLabel.isHidden = answer != nil || step != nil
        noteLabel.isHidden = answer?.note.isEmpty ?? true
        noteLabel.text = answer?.note
        field.isEnabled = step == nil
        updateSuggestButton()

        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.picks])
        snapshot.appendItems(answer.map(rows) ?? [])
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

    /// Asks for picks. What to Watch is part of Crucible Pro and of a Pro Week; a viewer without either is answered
    /// once on this device as a taste, and after that asking opens the paywall.
    private func suggest() {
        let request = request
        guard !request.isEmpty else { return }
        if case .working = phase { return }
        field.resignFirstResponder()
        switch ProAccess.shared.tasteAccess(to: .whatToWatch) {
        case .whole:
            run(request, asTaste: false)
        case .taste:
            run(request, asTaste: true)
        case .locked:
            ProAccess.shared.requestUnlock(.whatToWatch) { [weak self] unlocked in
                guard unlocked, let self else { return }
                self.run(request, asTaste: false)
            }
        }
    }

    private func run(_ request: String, asTaste: Bool) {
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
                if asTaste { ProAccess.shared.noteTasteGiven(.whatToWatch) }
                self.answerIsTaste = asTaste
                self.phase = .answered(answer)
                DemoTour.shared.record(.whatToWatch)
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

    /// The row between the first pick and the sealed ones is words and a button of its own, not a row to press.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource?.itemIdentifier(for: indexPath) != .seal
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .answered(let answer) = phase, let row = dataSource?.itemIdentifier(for: indexPath) else { return }
        guard case .pick(let id) = row, let pick = answer.picks.first(where: { $0.id == id }) else {
            if case .sealedPick = row { unseal() }
            return
        }
        switch pick.title.kind {
        case .movie: navigationController?.pushViewController(MediaDetailViewController(api: api, ratingKey: pick.id, mediaType: "movie"), animated: true)
        case .show: navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: pick.id), animated: true)
        }
    }

    /// The look of this screen's buttons: the accent colour for the one that acts or is chosen, grey for the rest.
    private static func capsule(_ title: String, filled: Bool) -> UIButton.Configuration {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.title = title
        if filled {
            configuration.baseBackgroundColor = Theme.Color.accent
            configuration.baseForegroundColor = .black
        } else {
            configuration.baseForegroundColor = Theme.Color.label
        }
        return configuration
    }

    private static func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: capsule(title, filled: filled), primaryAction: UIAction { _ in action() })
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
