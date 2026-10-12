import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The Crucible Pro sheet. It draws `PaywallModel` and nothing else: every phase, notice and busy state comes from the model,
/// and a finished model either dismisses the sheet with the pending action unlocked or leaves it as it was.
final class PaywallViewController: UIViewController, UISheetPresentationControllerDelegate {
    static func present(_ request: PaywallRequest, from presenter: UIViewController, completion: @escaping @MainActor (Bool) -> Void) {
        let controller = PaywallViewController(model: PaywallModel(request: request), completion: completion)
        presenter.present(controller, animated: true)
    }

    private let model: PaywallModel
    private let completion: @MainActor (Bool) -> Void
    private var didComplete = false
    private var dismissedBySystem = false
    private var didStart = false
    private var proObservation: ProObservation?
    private var renderedPhase: PaywallModel.Phase?
    private var shownNotice: PaywallModel.Notice?
    private var cards: [String: PaywallOfferCardView] = [:]

    private let rootStack = UIStackView()
    private let closeButton = ThemeButton.icon(symbol: "xmark", label: "Close", size: 36)
    private let noticeBanner = PaywallNoticeBannerView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let glyph = CrystalGlyphView()
    private let subtitleLabel = UILabel()
    private let offersStack = UIStackView()
    private let footerContainer = UIView()
    private let footerStack = UIStackView()
    private let disclosureLabel = UILabel()
    private let ctaButton = ThemeButton.primary(title: "Loading\u{2026}")
    private let linksStack = UIStackView()
    private let restoreButton = UIButton(configuration: .plain())
    private let termsButton = UIButton(configuration: .plain())
    private let privacyButton = UIButton(configuration: .plain())

    init(model: PaywallModel, completion: @escaping @MainActor (Bool) -> Void) {
        self.model = model
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.delegate = self
            if #unavailable(iOS 26.0) {
                sheet.preferredCornerRadius = 32
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        view.tintColor = Theme.Color.accent
        buildLayout()
        placeFooter()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: PaywallViewController, _: UITraitCollection) in
            controller.placeFooter()
        }
        model.onChange = { [weak self] state in self?.render(state, animated: true) }
        model.onFinish = { [weak self] unlocked in self?.finish(unlocked: unlocked) }
        proObservation = ProObservation { [weak self] in
            guard ProAccess.shared.isPro else { return }
            self?.model.start()
        }
        render(model.state, animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !UIAccessibility.isReduceMotionEnabled { glyph.startBreathing() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        model.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard !model.state.isBusy else { return false }
        model.cancel()
        return true
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        dismissedBySystem = true
        model.cancel()
    }

    private func finish(unlocked: Bool) {
        guard !didComplete else { return }
        didComplete = true
        if unlocked { Haptics.success() }
        let completion = completion
        guard !dismissedBySystem, presentingViewController != nil else {
            completion(unlocked)
            return
        }
        dismiss(animated: true) { completion(unlocked) }
    }

    // MARK: - Layout

    private func buildLayout() {
        closeButton.addAction(UIAction { [weak self] _ in self?.model.cancel() }, for: .primaryActionTriggered)
        let topBar = UIStackView(arrangedSubviews: [UIView(), closeButton])
        topBar.isLayoutMarginsRelativeArrangement = true
        topBar.layoutMargins = UIEdgeInsets(top: 20, left: 16, bottom: 0, right: 16)

        noticeBanner.onDismiss = { [weak self] in self?.model.dismissNotice() }
        noticeBanner.isHidden = true
        let noticeWrap = UIStackView(arrangedSubviews: [noticeBanner])
        noticeWrap.isLayoutMarginsRelativeArrangement = true
        noticeWrap.layoutMargins = UIEdgeInsets(top: 8, left: 20, bottom: 4, right: 20)
        noticeWrap.isHidden = true

        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.axis = .vertical
        contentStack.spacing = 22
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 4, left: 20, bottom: 24, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        contentStack.addArrangedSubview(makeHeader())
        contentStack.addArrangedSubview(makeFeatures())
        offersStack.axis = .vertical
        offersStack.spacing = 12
        contentStack.addArrangedSubview(offersStack)

        buildFooter()

        rootStack.axis = .vertical
        rootStack.addArrangedSubview(topBar)
        rootStack.addArrangedSubview(noticeWrap)
        rootStack.addArrangedSubview(scrollView)
        rootStack.addArrangedSubview(footerContainer)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func makeHeader() -> UIView {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 80),
            glyph.heightAnchor.constraint(equalToConstant: 80),
        ])
        let glyphRow = UIStackView(arrangedSubviews: [UIView(), glyph, UIView()])
        glyphRow.distribution = .equalCentering

        let title = UILabel()
        title.text = "Crucible Pro"
        title.font = Theme.Font.title1
        title.textColor = Theme.Color.label
        title.textAlignment = .center
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header

        subtitleLabel.text = Self.subtitle(for: model.request)
        subtitleLabel.font = Theme.Font.callout
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.adjustsFontForContentSizeCategory = true

        let header = UIStackView(arrangedSubviews: [glyphRow, title, subtitleLabel])
        header.axis = .vertical
        header.spacing = 6
        header.setCustomSpacing(10, after: glyphRow)
        return header
    }

    private static func subtitle(for request: PaywallRequest) -> String {
        guard let feature = request.feature else { return "Unlock downloads, full Statistics and the poster" }
        return "\(feature.title) is part of Crucible Pro"
    }

    private func makeFeatures() -> UIView {
        let stack = UIStackView(arrangedSubviews: ProFeature.listed(isTV: false).map {
            PaywallFeatureRowView(feature: $0, isHighlighted: $0 == model.request.feature)
        })
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }

    private func buildFooter() {
        disclosureLabel.font = Theme.Font.caption1Regular
        disclosureLabel.textColor = Theme.Color.labelSecondary
        disclosureLabel.textAlignment = .center
        disclosureLabel.numberOfLines = 0
        disclosureLabel.adjustsFontForContentSizeCategory = true
        disclosureLabel.isHidden = true

        ctaButton.addAction(UIAction { [weak self] _ in
            Haptics.medium()
            self?.model.purchaseSelected()
        }, for: .primaryActionTriggered)

        configureLink(restoreButton, title: "Restore Purchases", color: Theme.Color.accentText) { [weak self] in
            Haptics.selection()
            self?.model.restore()
        }
        configureLink(termsButton, title: "Terms of Use", color: Theme.Color.labelSecondary) { UIApplication.shared.open(ProLinks.termsOfUse) }
        configureLink(privacyButton, title: "Privacy Policy", color: Theme.Color.labelSecondary) { UIApplication.shared.open(ProLinks.privacyPolicy) }
        termsButton.accessibilityTraits = .link
        privacyButton.accessibilityTraits = .link
        for button in [restoreButton, termsButton, privacyButton] {
            linksStack.addArrangedSubview(button)
        }
        linksStack.distribution = .fillProportionally
        linksStack.alignment = .center

        footerStack.axis = .vertical
        footerStack.spacing = 10
        footerStack.isLayoutMarginsRelativeArrangement = true
        for view in [disclosureLabel, ctaButton, linksStack] {
            footerStack.addArrangedSubview(view)
        }

        footerContainer.backgroundColor = Theme.Color.canvas
        let hairline = UIView()
        hairline.backgroundColor = Theme.Color.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])
    }

    private func configureLink(_ button: UIButton, title: String, color: UIColor, action: @escaping () -> Void) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = color
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 4, bottom: 10, trailing: 4)
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.footnoteSemibold
            return outgoing
        }
        button.configuration = config
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget).isActive = true
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    }

    /// The footer stays pinned under the scrolling offers, except at the largest text sizes, where it would
    /// fill the screen: there it scrolls with the rest of the sheet and the links stack vertically.
    private func placeFooter() {
        let inline = traitCollection.preferredContentSizeCategory >= .extraExtraLarge
        footerStack.removeFromSuperview()
        linksStack.axis = inline ? .vertical : .horizontal
        linksStack.spacing = inline ? 0 : 4
        footerContainer.isHidden = inline
        if inline {
            footerStack.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
            contentStack.addArrangedSubview(footerStack)
        } else {
            footerStack.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 4, right: 20)
            footerStack.translatesAutoresizingMaskIntoConstraints = false
            footerContainer.addSubview(footerStack)
            NSLayoutConstraint.activate([
                footerStack.topAnchor.constraint(equalTo: footerContainer.topAnchor),
                footerStack.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
                footerStack.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
                footerStack.bottomAnchor.constraint(equalTo: footerContainer.safeAreaLayoutGuide.bottomAnchor),
            ])
        }
    }

    // MARK: - Rendering

    private func render(_ state: PaywallModel.State, animated: Bool) {
        let shouldAnimate = animated && view.window != nil && !UIAccessibility.isReduceMotionEnabled
        let changes = { [self] in
            isModalInPresentation = state.isBusy
            closeButton.isEnabled = !state.isBusy
            renderOffers(state)
            renderPurchaseControls(state)
            renderNotice(state.notice)
            view.layoutIfNeeded()
        }
        if shouldAnimate {
            UIView.animate(withDuration: 0.25, animations: changes)
        } else {
            changes()
        }
    }

    private func renderOffers(_ state: PaywallModel.State) {
        if state.phase != renderedPhase {
            renderedPhase = state.phase
            offersStack.arrangedSubviews.forEach {
                offersStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            cards = [:]
            switch state.phase {
            case .loading:
                offersStack.addArrangedSubview(makeSkeleton())
            case .ready(let offers):
                for offer in offers {
                    let card = PaywallOfferCardView(offer: offer)
                    card.addAction(UIAction { [weak self] _ in
                        Haptics.selection()
                        self?.model.select(offer.id)
                    }, for: .primaryActionTriggered)
                    cards[offer.id] = card
                    offersStack.addArrangedSubview(card)
                }
            case .unavailable(let message):
                offersStack.addArrangedSubview(makeUnavailable(message: message))
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        for (id, card) in cards {
            card.isSelected = id == state.selectedOfferID
            card.isEnabled = !state.isBusy
        }
    }

    private func renderPurchaseControls(_ state: PaywallModel.State) {
        var restoring = false
        var purchasing = false
        switch state.busy {
        case .idle: break
        case .purchasing: purchasing = true
        case .restoring: restoring = true
        }

        var config = ctaButton.configuration ?? ThemeButton.primaryConfiguration(title: "")
        switch state.phase {
        case .loading:
            config.title = "Loading\u{2026}"
            config.showsActivityIndicator = true
            ctaButton.isEnabled = false
            ctaButton.isUserInteractionEnabled = true
            ctaButton.accessibilityValue = "Loading prices"
        case .unavailable:
            config.showsActivityIndicator = false
        case .ready:
            config.title = state.selectedOffer?.buttonTitle ?? "Continue"
            config.showsActivityIndicator = purchasing
            ctaButton.isEnabled = !restoring
            ctaButton.isUserInteractionEnabled = !state.isBusy
            ctaButton.accessibilityValue = purchasing ? "Purchasing" : nil
        }
        ctaButton.configuration = config
        ctaButton.accessibilityTraits = purchasing ? [.button, .notEnabled] : .button
        ctaButton.isHidden = state.phase.isUnavailable

        let disclosure = state.selectedOffer?.renewalDisclosure
        disclosureLabel.text = disclosure
        disclosureLabel.isHidden = disclosure == nil

        var restoreConfig = restoreButton.configuration
        restoreConfig?.title = restoring ? "Restoring\u{2026}" : "Restore Purchases"
        restoreConfig?.showsActivityIndicator = restoring
        restoreButton.configuration = restoreConfig
        restoreButton.isEnabled = !state.isBusy
        termsButton.isEnabled = !state.isBusy
        privacyButton.isEnabled = !state.isBusy
    }

    private func renderNotice(_ notice: PaywallModel.Notice?) {
        guard notice != shownNotice else { return }
        shownNotice = notice
        let wrap = noticeBanner.superview
        guard let notice else {
            wrap?.isHidden = true
            noticeBanner.isHidden = true
            return
        }
        noticeBanner.show(notice)
        noticeBanner.isHidden = false
        wrap?.isHidden = false
        if case .failure = notice { Haptics.error() }
        UIAccessibility.post(notification: .announcement, argument: PaywallModel.message(for: notice))
    }

    private func makeSkeleton() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        for _ in 0..<2 {
            let placeholder = UIView()
            placeholder.backgroundColor = Theme.Color.surface
            placeholder.layer.cornerRadius = Theme.Radius.m
            placeholder.layer.cornerCurve = .continuous
            placeholder.heightAnchor.constraint(equalToConstant: 96).isActive = true
            stack.addArrangedSubview(placeholder)
        }
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "Loading prices"
        stack.accessibilityTraits = .updatesFrequently
        if !UIAccessibility.isReduceMotionEnabled {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.45
            pulse.toValue = 1
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            stack.layer.add(pulse, forKey: "pulse")
        }
        return stack
    }

    private func makeUnavailable(message: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
        icon.tintColor = Theme.Color.accent
        icon.contentMode = .center
        icon.isAccessibilityElement = false

        let label = UILabel()
        label.text = message
        label.font = Theme.Font.callout
        label.textColor = Theme.Color.label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true

        var config = ThemeButton.glassConfiguration(title: "Try Again", symbol: "arrow.clockwise")
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        let retry = UIButton(configuration: config)
        retry.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.model.retry()
        }, for: .primaryActionTriggered)
        retry.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget).isActive = true

        let retryRow = UIStackView(arrangedSubviews: [UIView(), retry, UIView()])
        retryRow.distribution = .equalCentering

        let card = UIStackView(arrangedSubviews: [icon, label, retryRow])
        card.axis = .vertical
        card.spacing = 12
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 22, left: 18, bottom: 22, right: 18)
        card.backgroundColor = Theme.Color.surface
        card.layer.cornerRadius = Theme.Radius.m
        card.layer.cornerCurve = .continuous
        return card
    }
}

private extension PaywallModel.Phase {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
