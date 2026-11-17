import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The welcome a library gets the first time it opens on this device: where the viewer stands with Crucible Pro and what it holds for
/// them, what Trakt would add, and Start Watching. It rises over Home once Home is up and lays itself out again when the store or Trakt
/// answers while it is open.
final class WelcomeViewController: DemoSheetViewController {
    var onFinished: (() -> Void)?

    private let serverName: String
    private let api: APIClient
    private let standingCard = UIStackView()
    private let traktCard = UIStackView()
    private let features = UIStackView()
    private let proButtonSlot = UIStackView()
    private var proObserver: UUID?
    private var traktObserver: UUID?
    private var hasEntered = false
    private var hasFinished = false
    private var rendered: WelcomePlan?

    init(serverName: String, api: APIClient) {
        self.serverName = serverName
        self.api = api
        super.init(detents: [.large()])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let pro = proObserver, trakt = traktObserver
        Task { @MainActor in
            if let pro { ProAccess.shared.stopObserving(pro) }
            if let trakt { TraktAccount.shared.stopObserving(trakt) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "welcome"
        addHeader(title: WelcomeCopy.title, body: WelcomeCopy.connected(to: serverName))
        for card in [standingCard, traktCard, features] {
            card.axis = .vertical
            card.spacing = Theme.Space.xs
            contentStack.addArrangedSubview(card)
        }
        contentStack.setCustomSpacing(Theme.Space.s, after: standingCard)
        contentStack.setCustomSpacing(Theme.Space.l, after: traktCard)

        let start = ThemeButton.primary(title: WelcomeCopy.start)
        start.accessibilityIdentifier = "welcome.start"
        start.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        addAction(start)
        proButtonSlot.axis = .vertical
        actionStack.addArrangedSubview(proButtonSlot)

        render()
        proObserver = ProAccess.shared.observe { [weak self] _ in self?.render() }
        traktObserver = TraktAccount.shared.observe { [weak self] in self?.render() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !hasEntered else { return }
        prepareEntrance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        playEntrance()
        if rendered?.celebrates == true { Haptics.success() }
        UIAccessibility.post(notification: .screenChanged, argument: view)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil, !hasFinished else { return }
        hasFinished = true
        onFinished?()
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private var plan: WelcomePlan {
        WelcomePlan.current()
    }

    /// Lays the two cards out for the plan as it stands now; an answer that changes nothing leaves them as they are.
    private func render() {
        let plan = plan
        guard plan != rendered else { return }
        let animated = rendered != nil && view.window != nil
        rendered = plan
        let apply = {
            self.fillStanding(plan)
            self.fillTrakt(plan.trakt)
            self.fillProButton(plan.offersPro)
        }
        guard animated else { return apply() }
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.3
        UIView.transition(with: contentStack, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply)
    }

    /// The standing card, then what it holds: Pro's features while Pro is open, else what the free app does. Trakt sits between the
    /// two, so its invitation is on screen without scrolling.
    private func fillStanding(_ plan: WelcomePlan) {
        standingCard.arrangedSubviews.forEach { $0.removeFromSuperview() }
        standingCard.addArrangedSubview(WelcomeStandingView(plan: plan))
        features.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows: [UIView]
        if plan.listsProFeatures {
            rows = ProFeature.listed(isTV: false).map { PaywallFeatureRowView(feature: $0, summary: $0.summary, isHighlighted: false) }
        } else {
            rows = plan.freeHighlights(includingDownloads: true).map { PaywallFeatureRowView(symbol: $0.symbol, title: $0.title, summary: $0.detail) }
        }
        rows.forEach(features.addArrangedSubview)
    }

    private func fillTrakt(_ step: WelcomePlan.TraktStep?) {
        traktCard.arrangedSubviews.forEach { $0.removeFromSuperview() }
        traktCard.isHidden = step == nil
        guard let step else { return }
        traktCard.addArrangedSubview(WelcomeTraktView(step: step) { [weak self] in self?.connectTrakt() })
    }

    private func fillProButton(_ offersPro: Bool) {
        proButtonSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard offersPro else { return }
        let seePro = makeLinkButton(title: WelcomeCopy.seePro) { [weak self] in
            guard let self else { return }
            PaywallPresenter.showOffer(from: self)
        }
        seePro.accessibilityIdentifier = "welcome.pro"
        proButtonSlot.addArrangedSubview(seePro)
    }

    private func connectTrakt() {
        TraktInviteSheet.present(from: self, api: api)
    }

    /// Everything on the sheet starts a little low and clear, so it can rise into place in turn once the sheet is up.
    private func prepareEntrance() {
        let lift = UIAccessibility.isReduceMotionEnabled ? 0 : 18
        for view in entranceViews {
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: CGFloat(lift))
        }
    }

    private func playEntrance() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        for (index, view) in entranceViews.enumerated() {
            UIView.animate(
                withDuration: reduceMotion ? 0.25 : 0.6,
                delay: reduceMotion ? 0 : 0.07 * Double(index),
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    /// The header, the standing card, the Trakt card and each line under them, top to bottom: the order they rise in.
    private var entranceViews: [UIView] {
        let header = contentStack.arrangedSubviews.first.map { [$0] } ?? []
        return header + [standingCard, traktCard] + features.arrangedSubviews
    }
}

/// Where the viewer stands with Crucible Pro: a symbol in the accent's well, the heading and what it means.
private final class WelcomeStandingView: UIView {
    init(plan: WelcomePlan) {
        super.init(frame: .zero)
        backgroundColor = plan.listsProFeatures ? Theme.Color.accentTint : Theme.Color.surfaceRaised
        layer.cornerRadius = Theme.Radius.l
        layer.cornerCurve = .continuous

        let well = UIView()
        well.backgroundColor = Theme.Color.accent
        well.layer.cornerRadius = 22
        well.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: plan.standingSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
        icon.tintColor = Theme.Color.onAccent
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)

        let title = UILabel()
        title.text = plan.standingTitle
        title.font = Theme.Font.title3
        title.textColor = Theme.Color.label
        title.accessibilityTraits = .header
        let message = UILabel()
        message.text = plan.standingMessage
        message.font = Theme.Font.callout
        message.textColor = Theme.Color.labelSecondary
        for label in [title, message] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [title, message])
        text.axis = .vertical
        text.spacing = 4
        let row = UIStackView(arrangedSubviews: [well, text])
        row.alignment = .top
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 44),
            well.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.m),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
        ])
        accessibilityIdentifier = "welcome.standing"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// What Trakt adds, with Connect Trakt, or the account it is connected as.
private final class WelcomeTraktView: UIView {
    private let onAction: () -> Void

    init(step: WelcomePlan.TraktStep, onAction: @escaping () -> Void) {
        self.onAction = onAction
        super.init(frame: .zero)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = Theme.Radius.l
        layer.cornerCurve = .continuous

        let markWell = UIView()
        markWell.backgroundColor = .white
        markWell.layer.cornerRadius = 22
        markWell.translatesAutoresizingMaskIntoConstraints = false
        let mark = UIImageView(image: BrandMark.trakt.image)
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        markWell.addSubview(mark)

        let title = UILabel()
        title.text = WelcomeCopy.title(of: step)
        title.font = Theme.Font.headline
        title.textColor = Theme.Color.label
        let message = UILabel()
        message.text = WelcomeCopy.message(of: step)
        message.font = Theme.Font.subheadline
        message.textColor = Theme.Color.labelSecondary
        for label in [title, message] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [title, message])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 4
        if let action = WelcomeCopy.action(of: step) {
            text.setCustomSpacing(Theme.Space.s, after: message)
            text.addArrangedSubview(makeButton(action))
        }
        let row = UIStackView(arrangedSubviews: [markWell, text])
        row.alignment = .top
        row.spacing = 14
        if case .connected = step {
            let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2)))
            check.tintColor = Theme.Color.statusOK
            check.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(check)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            markWell.widthAnchor.constraint(equalToConstant: 44),
            markWell.heightAnchor.constraint(equalToConstant: 44),
            mark.centerXAnchor.constraint(equalTo: markWell.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: markWell.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 26),
            mark.heightAnchor.constraint(equalToConstant: 26),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.m),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
        ])
        accessibilityIdentifier = "welcome.trakt"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ title: String) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.accentText
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.subheadlineSemibold
            return outgoing
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            Haptics.light()
            self?.onAction()
        })
        button.accessibilityIdentifier = "welcome.trakt.connect"
        button.isPointerInteractionEnabled = true
        return button
    }
}
