import CrucibleCore
import CrucibleDesign
import UIKit

/// A show's Previously On. With a paired Crucible Server it is a short read of the episodes watched so far, written
/// from what was said, with what it draws on and the computer that wrote it. Without one it is the last finished
/// episodes' own descriptions, which Crucible's AI writes into one recap when the person asks for that.
///
/// A viewer without Crucible Pro is given one written recap as a taste (`ProTasteStore`): how it begins, its next
/// lines fading out, and the button that opens the rest.
final class PreviouslyOnViewController: UIViewController {
    private let model: ShowDetailModel
    private let offer: PreviouslyOnOffer
    private let episodes: [DescribedEpisode]
    private let episodeList = UIStackView()
    private let sendsLabel = UILabel()
    private let serverLabel = UILabel()
    private lazy var writeButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.title = DescribedRecapCopy.write
        configuration.image = UIImage(systemName: "sparkles")
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = Theme.Color.accent
        configuration.baseForegroundColor = .black
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.writeRecap() })
        button.accessibilityIdentifier = "previouslyOn.write"
        return button
    }()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let basisLabel = UILabel()
    private let restView = FadingTextView(font: Theme.Font.body, color: Theme.Color.label)
    private let sealedLabel = UILabel()
    private lazy var readWholeButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.title = DescribedRecapCopy.readWhole
        configuration.image = ProLock.image()
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = Theme.Color.accent
        configuration.baseForegroundColor = .black
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.unseal() })
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = "previouslyOn.unseal"
        return button
    }()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var task: Task<Void, Never>?
    /// The whole recap while only how it begins is shown, kept so Crucible Pro opens it without asking again.
    private var sealedRecap: String?
    private lazy var proObservation = ProObservation { [weak self] in self?.unsealIfProArrived() }

    init(model: ShowDetailModel) {
        self.model = model
        self.offer = PreviouslyOnRequest.offer(model)
        self.episodes = DescribedRecap.episodes(of: model)
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

        sealedLabel.font = Theme.Font.footnote
        sealedLabel.textColor = Theme.Color.labelSecondary
        sealedLabel.numberOfLines = 0
        sealedLabel.adjustsFontForContentSizeCategory = true
        sealedLabel.text = DescribedRecapCopy.sealedNote
        [restView, sealedLabel, readWholeButton].forEach { $0.isHidden = true }

        let stack = UIStackView(arrangedSubviews: [titleLabel, spinner, bodyLabel, restView, sealedLabel, readWholeButton, basisLabel, writeButton, sendsLabel, episodeList, serverLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.m
        stack.setCustomSpacing(Theme.Space.xs, after: bodyLabel)
        _ = proObservation
        buildDescriptions()
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
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.l),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ] + besideTheBar(stack))
        if offer == .server { load() }
    }

    /// Keeps the text between the sheet's safe edges. On iPhone Duo's outer display the sheet's bar stands on the
    /// trailing edge with Done in it, beside the text and not above it, and a title as wide as the sheet ran under
    /// that button.
    private func besideTheBar(_ stack: UIStackView) -> [NSLayoutConstraint] {
        [
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Space.l),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Space.l),
        ]
    }

    /// Lays out the described form: the episodes as Plex describes them, the button that has them written into one
    /// recap where this build has Crucible's AI, what pressing it sends, and what Crucible Server would add.
    private func buildDescriptions() {
        let isDescribed = offer != .server
        let canWrite = isDescribed && DescribedRecap.canWrite(show: model.show.title, episodes: episodes)
        [episodeList, serverLabel].forEach { $0.isHidden = !isDescribed }
        [writeButton, sendsLabel].forEach { $0.isHidden = !canWrite }
        guard isDescribed else { return }
        spinner.stopAnimating()
        spinner.isHidden = true
        bodyLabel.isHidden = true
        basisLabel.isHidden = true
        for label in [sendsLabel, serverLabel] {
            label.font = Theme.Font.footnote
            label.textColor = Theme.Color.labelSecondary
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        sendsLabel.text = DescribedRecapCopy.sends
        serverLabel.text = DescribedRecapCopy.withServer
        episodeList.axis = .vertical
        episodeList.spacing = Theme.Space.m
        episodeList.accessibilityIdentifier = "previouslyOn.episodes"
        for episode in episodes {
            let heading = UILabel()
            heading.font = Theme.Font.subheadlineSemibold
            heading.textColor = Theme.Color.label
            heading.numberOfLines = 0
            heading.adjustsFontForContentSizeCategory = true
            heading.text = episode.code == episode.title ? episode.title : "\(episode.code) · \(episode.title)"
            let description = UILabel()
            description.font = Theme.Font.subheadline
            description.textColor = Theme.Color.labelSecondary
            description.numberOfLines = 0
            description.adjustsFontForContentSizeCategory = true
            description.text = episode.description
            let block = UIStackView(arrangedSubviews: [heading, description])
            block.axis = .vertical
            block.spacing = 2
            episodeList.addArrangedSubview(block)
        }
    }

    /// Has the descriptions written into one recap. That is part of Crucible Pro and of a Pro Week; a viewer without
    /// either is given one recap on this device as a taste, and after that asking opens the paywall.
    private func writeRecap() {
        guard task == nil else { return }
        switch ProAccess.shared.tasteAccess(to: .writtenRecap) {
        case .whole:
            startWriting(asTaste: false)
        case .taste:
            startWriting(asTaste: true)
        case .locked:
            ProAccess.shared.requestUnlock(.previouslyOn) { [weak self] unlocked in
                guard unlocked, let self else { return }
                self.startWriting(asTaste: false)
            }
        }
    }

    /// Shows a recap that was written: all of it, or for a taste how it begins with the rest sealed. A recap too
    /// short to split is shown whole.
    private func show(_ recap: String, asTaste: Bool) {
        let taste = DescribedRecap.taste(of: recap)
        let seals = asTaste && !ProAccess.shared.hasFullAccess && !taste.rest.isEmpty
        sealedRecap = seals ? recap : nil
        bodyLabel.text = seals ? taste.opening : recap
        restView.text = seals ? taste.rest : nil
        [restView, sealedLabel, readWholeButton].forEach { $0.isHidden = !seals }
        basisLabel.text = DescribedRecap.basis(episodes)
        basisLabel.isHidden = false
        writeButton.isHidden = true
        sendsLabel.isHidden = true
    }

    /// Opens the paywall from a recap shown in part; once Crucible Pro is on, the rest of it is there to read.
    private func unseal() {
        ProAccess.shared.requestUnlock(.previouslyOn) { [weak self] unlocked in
            if unlocked { self?.openSealedRecap() }
        }
    }

    /// Pro can also arrive while a recap shown in part is on screen without this sheet asking: a purchase made
    /// elsewhere, or a Pro Week that starts.
    private func unsealIfProArrived() {
        if ProAccess.shared.hasFullAccess { openSealedRecap() }
    }

    private func openSealedRecap() {
        guard let recap = sealedRecap else { return }
        show(recap, asTaste: false)
        UIAccessibility.post(notification: .layoutChanged, argument: bodyLabel)
    }

    private func startWriting(asTaste: Bool) {
        Haptics.selection()
        writeButton.isEnabled = false
        spinner.isHidden = false
        spinner.startAnimating()
        bodyLabel.isHidden = false
        bodyLabel.text = DescribedRecapCopy.writing
        task = Task { [weak self] in
            guard let self else { return }
            do throws(HostedBrainError) {
                let recap = try await DescribedRecap.write(show: model.show.title, episodes: episodes)
                if asTaste, !Task.isCancelled { ProAccess.shared.noteTasteGiven(.writtenRecap) }
                show(recap, asTaste: asTaste)
                Haptics.success()
            } catch {
                bodyLabel.text = DescribedRecapCopy.failure(error)
                writeButton.isEnabled = true
                Haptics.error()
            }
            spinner.stopAnimating()
            spinner.isHidden = true
            task = nil
            UIAccessibility.post(notification: .layoutChanged, argument: bodyLabel)
        }
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
