import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// Makes a shareable card of something the viewer watched: the card as it will be shared, live, over the choices that
/// shape it (movie, episode, season or show; the viewer's rating, saved to Plex as they set it; a few words of their own;
/// the look; what it shows) with Save and Share under them. The format sits in the title bar; every choice but the words
/// is remembered for the next card.
final class WatchCardComposerViewController: UIViewController, UITextFieldDelegate {
    private static let typingDelay: Duration = .milliseconds(90)
    private static let minimumStageHeight: CGFloat = 240

    private let api: APIClient
    private let origin: WatchCardOrigin
    private var scope: WatchCardScope
    private var facts: [WatchCardScope: WatchCardFacts] = [:]
    private var artworks: [WatchCardScope: WatchCardArtwork] = [:]
    private var setRatings: [String: UserRating] = [:]
    private var options = WatchCardOptions.saved()
    private var take = ""
    private var previewRating: UserRating?
    private var isPreviewingRating = false
    private var image: UIImage?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

    private let formatControl = UISegmentedControl(items: WatchCardFormat.allCases.map(\.title))
    private let scopeControl: UISegmentedControl
    private let stage = UIControl()
    private let frameView = UIView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let panelScroll = UIScrollView()
    private let panel = UIStackView()
    private let stars = StarRatingControl(starSize: 26, starSpacing: 6)
    private let ratingValue = UILabel()
    private let takeField = UITextField()
    private let styleRow = WatchCardStyleRow()
    private let optionChips = WatchCardOptionChips()
    private let saveButton = UIButton(configuration: ThemeButton.glassConfiguration(title: String(localized: "Save"), symbol: "square.and.arrow.down"))
    private let shareButton = ThemeButton.primary(title: String(localized: "Share"), symbol: "square.and.arrow.up")
    private let content = UIStackView()
    private var aspectConstraint: NSLayoutConstraint?
    private var appliedAxis: NSLayoutConstraint.Axis?

    init(api: APIClient, origin: WatchCardOrigin, rated: (ratingKey: String, rating: UserRating)? = nil) {
        self.api = api
        self.origin = origin
        self.scope = origin.startingScope
        if let rated { setRatings[rated.ratingKey] = rated.rating }
        self.scopeControl = UISegmentedControl(items: origin.scopes.map { origin.title(for: $0) })
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        renderTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        view.tintColor = Theme.Color.accent
        view.accessibilityIdentifier = "watchCard"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        setUpFormat()
        setUpStage()
        setUpPanel()
        setUpButtons()
        layOut()
        applyOptionsToControls()
        load(scope)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateAxis()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keepWordsInView()
    }

    /// While the viewer writes, the field stays in view as the keyboard takes the room under it.
    private func keepWordsInView() {
        guard takeField.isFirstResponder else { return }
        let field = panelScroll.convert(takeField.bounds, from: takeField).insetBy(dx: 0, dy: -Theme.Space.xs)
        let visible = CGRect(origin: panelScroll.contentOffset, size: panelScroll.bounds.size)
        guard !visible.contains(field) else { return }
        panelScroll.scrollRectToVisible(field, animated: false)
    }

    // MARK: - Set-up

    private func setUpFormat() {
        formatControl.accessibilityIdentifier = "watchCard.format"
        formatControl.addAction(UIAction { [weak self] _ in
            guard let self, WatchCardFormat.allCases.indices.contains(formatControl.selectedSegmentIndex) else { return }
            Haptics.selection()
            options.format = WatchCardFormat.allCases[formatControl.selectedSegmentIndex]
            optionsChanged(transition: true)
        }, for: .valueChanged)
        formatControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        navigationItem.titleView = formatControl
    }

    private func setUpStage() {
        frameView.layer.shadowColor = UIColor.black.cgColor
        frameView.layer.shadowOpacity = 0.32
        frameView.layer.shadowRadius = 22
        frameView.layer.shadowOffset = CGSize(width: 0, height: 12)
        frameView.translatesAutoresizingMaskIntoConstraints = false

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 14
        imageView.layer.cornerCurve = .continuous
        imageView.layer.borderWidth = 1
        imageView.layer.borderColor = Theme.Color.artHairline.cgColor
        imageView.backgroundColor = Theme.Color.surface
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityIdentifier = "watchCard.preview"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(UILayoutPriority(1), for: axis)
            imageView.setContentHuggingPriority(UILayoutPriority(1), for: axis)
        }

        spinner.color = Theme.Color.labelSecondary
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        frameView.addSubview(imageView)
        stage.addSubview(frameView)
        stage.addSubview(spinner)
        frameView.isUserInteractionEnabled = false
        stage.addAction(UIAction { [weak self] _ in self?.view.endEditing(true) }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: frameView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            frameView.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            frameView.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor),
            frameView.heightAnchor.constraint(lessThanOrEqualTo: stage.heightAnchor),
            spinner.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])
        let minimumHeight = stage.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumStageHeight)
        minimumHeight.priority = UILayoutPriority(999)
        minimumHeight.isActive = true
        let fillHeight = frameView.heightAnchor.constraint(equalTo: stage.heightAnchor)
        fillHeight.priority = UILayoutPriority(700)
        let fillWidth = frameView.widthAnchor.constraint(equalTo: stage.widthAnchor)
        fillWidth.priority = UILayoutPriority(699)
        NSLayoutConstraint.activate([fillHeight, fillWidth])
        addParallax()
    }

    /// The card drifts a few points against the phone's tilt, as a card held in the hand would.
    private func addParallax() {
        let horizontal = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        horizontal.minimumRelativeValue = -9
        horizontal.maximumRelativeValue = 9
        let vertical = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        vertical.minimumRelativeValue = -9
        vertical.maximumRelativeValue = 9
        let group = UIMotionEffectGroup()
        group.motionEffects = [horizontal, vertical]
        frameView.addMotionEffect(group)
    }

    private func setUpPanel() {
        scopeControl.accessibilityIdentifier = "watchCard.scope"
        scopeControl.selectedSegmentIndex = origin.scopes.firstIndex(of: scope) ?? 0
        scopeControl.isHidden = origin.scopes.count < 2
        scopeControl.addAction(UIAction { [weak self] _ in
            guard let self, origin.scopes.indices.contains(scopeControl.selectedSegmentIndex) else { return }
            Haptics.selection()
            view.endEditing(true)
            scope = origin.scopes[scopeControl.selectedSegmentIndex]
            load(scope)
        }, for: .valueChanged)

        stars.accessibilityIdentifier = "watchCard.stars"
        stars.addAction(UIAction { [weak self] _ in self?.ratingPreviewed() }, for: .valueChanged)
        stars.addAction(UIAction { [weak self] _ in self?.ratingCommitted() }, for: .primaryActionTriggered)
        let ratingTitle = UILabel()
        ratingTitle.text = UserRatingCopy.title
        ratingTitle.font = Theme.Font.subheadlineSemibold
        ratingTitle.textColor = Theme.Color.label
        ratingTitle.adjustsFontForContentSizeCategory = true
        ratingTitle.isAccessibilityElement = false
        ratingTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ratingValue.font = Theme.Font.scaled(.subheadline, 15, .semibold, maximum: 22)
        ratingValue.textColor = Theme.Color.labelSecondary
        ratingValue.adjustsFontForContentSizeCategory = true
        ratingValue.isAccessibilityElement = false
        ratingValue.setContentHuggingPriority(.required, for: .horizontal)
        let ratingRow = UIStackView(arrangedSubviews: [ratingTitle, UIView(), stars, ratingValue])
        ratingRow.alignment = .center
        ratingRow.spacing = Theme.Space.s

        takeField.placeholder = String(localized: "Add a few words of your own", comment: "Placeholder of the field where the viewer writes a short review onto their shared watch card")
        takeField.font = Theme.Font.body
        takeField.adjustsFontForContentSizeCategory = true
        takeField.textColor = Theme.Color.label
        takeField.backgroundColor = Theme.Color.surface
        takeField.layer.cornerRadius = 12
        takeField.layer.cornerCurve = .continuous
        takeField.returnKeyType = .done
        takeField.clearButtonMode = .whileEditing
        takeField.autocapitalizationType = .sentences
        takeField.delegate = self
        takeField.accessibilityIdentifier = "watchCard.take"
        takeField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        takeField.leftViewMode = .always
        takeField.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        takeField.addAction(UIAction { [weak self] _ in self?.takeChanged() }, for: .editingChanged)

        styleRow.onSelect = { [weak self] style in
            self?.options.style = style
            self?.optionsChanged(transition: true)
        }
        optionChips.onChange = { [weak self] option, isOn in
            guard let self else { return }
            switch option {
            case .rating: options.showsRating = isOn
            case .scores: options.showsScores = isOn
            case .details: options.showsDetails = isOn
            case .watched: options.showsWatched = isOn
            }
            optionsChanged(transition: false)
        }

        [scopeControl, ratingRow, takeField, styleRow, optionChips].forEach(panel.addArrangedSubview)
        panel.axis = .vertical
        panel.spacing = Theme.Space.m
        panel.setCustomSpacing(Theme.Space.s, after: styleRow)
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.xs, leading: 0, bottom: Theme.Space.xs, trailing: 0)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panelScroll.addSubview(panel)
        panelScroll.alwaysBounceVertical = false
        panelScroll.keyboardDismissMode = .interactive
        panelScroll.showsVerticalScrollIndicator = false
        let fitsContent = panelScroll.heightAnchor.constraint(equalTo: panel.heightAnchor)
        fitsContent.priority = UILayoutPriority(740)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.trailingAnchor),
            panel.widthAnchor.constraint(equalTo: panelScroll.frameLayoutGuide.widthAnchor),
            fitsContent,
        ])
    }

    private func setUpButtons() {
        saveButton.isPointerInteractionEnabled = true
        saveButton.accessibilityIdentifier = "watchCard.save"
        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .primaryActionTriggered)
        shareButton.accessibilityIdentifier = "watchCard.share"
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .primaryActionTriggered)
        saveButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func layOut() {
        content.addArrangedSubview(stage)
        content.addArrangedSubview(panelScroll)
        content.spacing = Theme.Space.m
        content.translatesAutoresizingMaskIntoConstraints = false
        stage.setContentHuggingPriority(.defaultLow, for: .vertical)
        stage.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let buttons = UIStackView(arrangedSubviews: [saveButton, shareButton])
        buttons.spacing = Theme.Space.s
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        view.addSubview(buttons)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.Space.s),
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Space.l),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Space.l),
            content.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -Theme.Space.m),
            buttons.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Space.l),
            buttons.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Space.l),
            buttons.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Space.s),
            shareButton.heightAnchor.constraint(equalToConstant: Theme.Size.primaryButtonHeight),
            saveButton.heightAnchor.constraint(equalTo: shareButton.heightAnchor),
        ])
        setButtonsEnabled(false)
    }

    /// Stage over the controls in a tall window, beside them in a wide one, such as a phone held sideways.
    private func updateAxis() {
        let bounds = view.bounds.size
        let axis: NSLayoutConstraint.Axis = bounds.width > bounds.height * 1.15 && bounds.width >= 560 ? .horizontal : .vertical
        guard appliedAxis != axis else { return }
        appliedAxis = axis
        content.axis = axis
        content.distribution = axis == .horizontal ? .fillEqually : .fill
    }

    private func applyOptionsToControls() {
        formatControl.selectedSegmentIndex = WatchCardFormat.allCases.firstIndex(of: options.format) ?? 0
        styleRow.select(options.style)
        optionChips.set(.rating, isOn: options.showsRating)
        optionChips.set(.scores, isOn: options.showsScores)
        optionChips.set(.details, isOn: options.showsDetails)
        optionChips.set(.watched, isOn: options.showsWatched)
        updateAspect()
    }

    /// Shows `format`, as picking it in the title bar does, for the screenshot harness.
    func select(_ format: WatchCardFormat) {
        formatControl.selectedSegmentIndex = WatchCardFormat.allCases.firstIndex(of: format) ?? 0
        formatControl.sendActions(for: .valueChanged)
    }

    /// Switches to `scope`, as the switch between cards does, for the screenshot harness.
    func select(_ scope: WatchCardScope) {
        guard let index = origin.scopes.firstIndex(of: scope) else { return }
        scopeControl.selectedSegmentIndex = index
        scopeControl.sendActions(for: .valueChanged)
    }

    /// Writes `words` into the field, as typing them does, for the screenshot harness.
    func write(_ words: String) {
        takeField.text = words
        takeField.sendActions(for: .editingChanged)
    }

    // MARK: - Loading

    private func load(_ scope: WatchCardScope) {
        loadTask?.cancel()
        contentUnavailableConfiguration = nil
        if facts[scope] != nil, artworks[scope] != nil {
            show(scope)
            return
        }
        setButtonsEnabled(false)
        stars.isEnabled = false
        spinner.startAnimating()
        UIView.animate(withDuration: 0.2) { self.imageView.alpha = 0.35 }
        loadTask = Task { [weak self, api, origin] in
            do {
                guard let subject = try await WatchCardLoader.load(scope, origin: origin, api: api) else {
                    self?.showFailure(DetailMessage.itemUnavailable, retry: false)
                    return
                }
                let loaded = WatchCardFacts(subject: subject)
                async let poster = Self.image(loaded.posterPath, width: 720)
                async let backdrop = Self.image(loaded.backdropPath, width: 960)
                let artwork = await WatchCardArtwork.prepare(poster: await poster, backdrop: await backdrop)
                guard !Task.isCancelled, let self else { return }
                facts[scope] = loaded
                artworks[scope] = artwork
                guard self.scope == scope else { return }
                show(scope)
            } catch is CancellationError {
                return
            } catch {
                MidgarLog.error("Watch card load failed scope=\(scope.rawValue): \(error.localizedDescription)", category: .networking)
                guard !Task.isCancelled else { return }
                self?.showFailure(ConnectionError.message(for: error), retry: true)
            }
        }
    }

    private static func image(_ path: String?, width: Int) async -> UIImage? {
        guard let path else { return nil }
        return await ImageLoader.shared.loadImage(path: path, width: width)
    }

    private func show(_ scope: WatchCardScope) {
        spinner.stopAnimating()
        guard facts[scope] != nil else { return }
        styleRow.adopt(artworks[scope]?.tone)
        stars.isEnabled = true
        isPreviewingRating = false
        stars.setRating(currentRating, animated: view.window != nil)
        updateRatingValue(currentRating)
        render(transition: image != nil)
        setButtonsEnabled(true)
    }

    private func showFailure(_ message: String, retry: Bool) {
        spinner.stopAnimating()
        setButtonsEnabled(false)
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "rectangle.portrait.slash")
        config.imageProperties.tintColor = Theme.Color.labelTertiary
        config.text = String(localized: "Couldn't Make the Card", comment: "Title shown on the watch card screen when the title could not be loaded")
        config.textProperties.font = Theme.Font.title3
        config.secondaryText = message
        if retry {
            var button = UIButton.Configuration.filled()
            button.title = String(localized: "Try Again")
            button.baseBackgroundColor = Theme.Color.accent
            button.baseForegroundColor = Theme.Color.onAccent
            button.cornerStyle = .capsule
            config.button = button
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                guard let self else { return }
                load(self.scope)
            }
        }
        contentUnavailableConfiguration = config
    }

    // MARK: - Rendering

    private var currentRating: UserRating? {
        guard let facts = facts[scope] else { return nil }
        return setRatings[facts.ratingKey] ?? facts.servedRating
    }

    private var draft: WatchCardDraft? {
        guard let facts = facts[scope], let artwork = artworks[scope] else { return nil }
        return WatchCardDraft(
            facts: facts,
            rating: isPreviewingRating ? previewRating : currentRating,
            take: take,
            options: options,
            artwork: artwork
        )
    }

    /// Draws the card now; `transition` cross-fades to it, for a new look, format or title rather than a typed letter.
    private func render(transition: Bool) {
        renderTask?.cancel()
        guard let draft else { return }
        let next = WatchCardRenderer.render(draft)
        image = next
        imageView.accessibilityLabel = draft.facts.spokenSummary(rating: draft.shownRating, take: draft.cleanTake)
        updateAspect()
        let apply = {
            self.imageView.image = next
            self.imageView.alpha = 1
            self.view.layoutIfNeeded()
        }
        guard transition, view.window != nil, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.transition(with: frameView, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply)
    }

    /// Draws the card once typing or a sliding finger pauses, so every letter does not cost a whole render.
    private func renderSoon() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingDelay)
            guard !Task.isCancelled else { return }
            self?.render(transition: false)
        }
    }

    private func updateAspect() {
        let pixels = options.format.pixelSize
        let ratio = CGFloat(pixels.width) / CGFloat(pixels.height)
        guard aspectConstraint?.multiplier != ratio else { return }
        aspectConstraint?.isActive = false
        let aspect = frameView.widthAnchor.constraint(equalTo: frameView.heightAnchor, multiplier: ratio)
        aspect.isActive = true
        aspectConstraint = aspect
    }

    private func optionsChanged(transition: Bool) {
        options.save()
        render(transition: transition)
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        saveButton.isEnabled = enabled
        shareButton.isEnabled = enabled
    }

    // MARK: - Rating

    private func ratingPreviewed() {
        previewRating = stars.rating
        isPreviewingRating = true
        updateRatingValue(stars.rating)
        renderSoon()
    }

    /// Saves the rating the finger lifted on, at once on the card and then on the server; one the server refuses goes
    /// back to what it was.
    private func ratingCommitted() {
        guard let rating = stars.rating, let facts = facts[scope] else { return }
        let key = facts.ratingKey
        let previous = setRatings[key]
        setRatings[key] = rating
        isPreviewingRating = false
        updateRatingValue(rating)
        render(transition: false)
        Task { @MainActor [weak self, api] in
            do {
                try await RatingService.setRating(rating, ratingKey: key, api: api)
                Haptics.success()
            } catch {
                Haptics.error()
                guard let self, setRatings[key] == rating else { return }
                setRatings[key] = previous
                guard self.facts[scope]?.ratingKey == key else { return }
                stars.setRating(currentRating, animated: true)
                updateRatingValue(currentRating)
                render(transition: false)
            }
        }
    }

    private func updateRatingValue(_ rating: UserRating?) {
        ratingValue.text = rating?.text
        ratingValue.isHidden = rating == nil
    }

    // MARK: - Words

    private func takeChanged() {
        take = takeField.text ?? ""
        renderSoon()
    }

    /// Holds the words to the length the card has room for; pasting more keeps what fits instead of nothing.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        let replaced = (current as NSString).replacingCharacters(in: range, with: string)
        guard replaced.count > WatchCardTake.limit else { return true }
        guard let swapped = Range(range, in: current) else { return false }
        let room = WatchCardTake.limit - (current.count - current[swapped].count)
        guard room > 0 else { return false }
        textField.text = current.replacingCharacters(in: swapped, with: string.prefix(room))
        textField.sendActions(for: .editingChanged)
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - Save and share

    private func share() {
        guard let image, let facts = facts[scope] else { return }
        view.endEditing(true)
        Haptics.light()
        let activity = UIActivityViewController(activityItems: [ImageShareItem(image: image, title: facts.shareTitle)], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        let described = "scope=\(facts.scope.rawValue) format=\(options.format.rawValue) style=\(options.style.rawValue)"
        activity.completionWithItemsHandler = { activityType, completed, _, _ in
            guard completed else { return }
            MidgarLog.info("Watch card shared \(described) to=\(activityType?.rawValue ?? "unknown")", category: .lifecycle)
        }
        present(activity, animated: true)
    }

    private func save() {
        guard let image, saveButton.isEnabled else { return }
        view.endEditing(true)
        saveButton.isEnabled = false
        saveButton.configuration?.showsActivityIndicator = true
        Task { [weak self] in
            let result = await PhotoLibrarySaver.save(image)
            guard let self else { return }
            saveButton.configuration?.showsActivityIndicator = false
            saveButton.isEnabled = shareButton.isEnabled
            switch result {
            case .saved:
                Haptics.success()
                announce(String(localized: "Saved to Photos", comment: "Confirmation after the watch card was saved to the photo library"), symbol: "checkmark.circle.fill")
            case .denied:
                Haptics.error()
                presentPhotosDenied()
            case .failed:
                Haptics.error()
                announce(String(localized: "Couldn't Save to Photos", comment: "Shown when the watch card could not be saved to the photo library"), symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// A toast under the title bar that VoiceOver reads out too.
    private func announce(_ text: String, symbol: String) {
        TraktToast.show(text, symbol: symbol, in: navigationController?.view ?? view, belowBar: navigationController != nil)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func presentPhotosDenied() {
        let alert = UIAlertController(
            title: String(localized: "Allow Adding to Photos", comment: "Title of the alert shown when Crucible may not save the watch card to the photo library"),
            message: String(localized: "To save cards, let Crucible add photos in Settings.", comment: "Message of the alert shown when Crucible may not save the watch card to the photo library"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Open Settings"), style: .default) { _ in
            if let settings = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(settings) }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
}
