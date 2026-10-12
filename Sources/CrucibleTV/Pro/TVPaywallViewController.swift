import CrucibleCore
import CrucibleDesign
import UIKit

/// The Crucible Pro paywall on Apple TV, a full-screen modal driven only by `PaywallModel`: what Pro includes on the left;
/// on the right the plans (Select chooses one), the separate button that buys the chosen plan, Restore Purchases, the
/// renewal terms while the annual plan is chosen and a status line. The legal pages are plain text, because tvOS has no links.
///
/// - Loading and an unavailable store use the shared `TVStateView`; the unavailable state focuses Retry.
/// - While the store works, controls dim and ignore Select but stay focusable, so focus never jumps; the button that was
///   pressed shows a spinner. A cancelled purchase returns to the ready state without a message.
/// - Menu closes the paywall at any time (`PaywallModel.cancel()`); a purchase or restore that finishes later still
///   reaches the screens that observe `ProAccess`.
@MainActor
final class TVPaywallViewController: UIViewController {
    private enum Layout {
        static let infoWidth: CGFloat = 800
        static let columnGap: CGFloat = 96
        static let verticalInset: CGFloat = 40
    }

    private let model: PaywallModel
    private let completion: @MainActor (Bool) -> Void
    private let backdrop = TVGradientView()
    private let scrollView = UIScrollView()
    private let columns = UIStackView()
    private let stateView = TVStateView()
    private let offersStack = UIStackView()
    private let statusPanel = TVPaywallStatusPanel()
    private let disclosureLabel = UILabel()
    private lazy var disclosurePanel = makeDisclosurePanel()
    private lazy var buyButton = makeBuyButton()
    private lazy var restoreButton = makeRestoreButton()
    private var cards: [String: TVPaywallOfferCard] = [:]
    private var cardOrder: [String] = []
    private var isFinished = false
    private var hasStarted = false
    private var renderedPhase: PaywallModel.Phase?

    private init(request: PaywallRequest, completion: @escaping @MainActor (Bool) -> Void) {
        model = PaywallModel(request: request)
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        title = "Crucible Pro"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Presents the paywall over `presenter`, whatever is on screen, and reports whether the user ended up with Pro once it is gone.
    static func present(_ request: PaywallRequest, from presenter: UIViewController, completion: @escaping @MainActor (Bool) -> Void) {
        let paywall = TVPaywallViewController(request: request, completion: completion)
        presenter.present(paywall, animated: TVMotion.animationsEnabled)
    }

    private var isShowingState: Bool { !stateView.isHidden }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        isShowingState ? [stateView] : [buyButton]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        view.accessibilityViewIsModal = true
        installBackdrop()
        installColumns()
        installStateView()
        model.onChange = { [weak self] state in self?.render(state) }
        model.onFinish = { [weak self] unlocked in self?.finish(unlocked: unlocked) }
        render(model.state)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        model.start()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else {
            super.pressesBegan(presses, with: event)
            return
        }
        model.cancel()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !presses.contains(where: { $0.type == .menu }) else { return }
        super.pressesEnded(presses, with: event)
    }

    private func render(_ state: PaywallModel.State) {
        switch state.phase {
        case .loading:
            showState(.loading(title: "Loading Crucible Pro\u{2026}"))
        case .unavailable(let message):
            showState(.error(
                title: "Crucible Pro Is Unavailable",
                message: message,
                retryTitle: "Retry",
                retry: { [weak self] in self?.model.retry() },
                secondary: TVStateView.Action(title: "Close") { [weak self] in self?.model.cancel() }
            ))
        case .ready(let offers):
            showContent()
            renderOffers(offers, state: state)
            renderControls(state)
            renderStatus(state)
        }
        guard state.phase != renderedPhase else { return }
        renderedPhase = state.phase
        refocus()
    }

    private func showState(_ state: TVStateView.State) {
        scrollView.isHidden = true
        backdrop.isHidden = true
        stateView.isHidden = false
        stateView.show(state)
    }

    private func showContent() {
        stateView.isHidden = true
        scrollView.isHidden = false
        backdrop.isHidden = false
    }

    private func renderOffers(_ offers: [ProOffer], state: PaywallModel.State) {
        let order = offers.map(\.id)
        if order != cardOrder { rebuildCards(offers) }
        for offer in offers {
            cards[offer.id]?.configure(offer: offer, isSelected: offer.id == state.selectedOfferID, isDimmed: state.isBusy)
        }
    }

    private func rebuildCards(_ offers: [ProOffer]) {
        offersStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = [:]
        cardOrder = offers.map(\.id)
        for offer in offers {
            let card = TVPaywallOfferCard()
            card.accessibilityIdentifier = Self.identifier(for: offer)
            let id = offer.id
            card.addAction(UIAction { [weak self] _ in self?.model.select(id) }, for: .primaryActionTriggered)
            cards[id] = card
            offersStack.addArrangedSubview(card)
        }
    }

    private func renderControls(_ state: PaywallModel.State) {
        let purchasing: Bool
        let restoring = state.busy == .restoring
        if case .purchasing = state.busy { purchasing = true } else { purchasing = false }

        let buyTitle = purchasing ? "Purchasing\u{2026}" : (state.selectedOffer?.buttonTitle ?? "Continue")
        update(buyButton, title: buyTitle, showsSpinner: purchasing, isDimmed: restoring)
        update(restoreButton, title: restoring ? "Restoring\u{2026}" : "Restore Purchases", showsSpinner: restoring, isDimmed: purchasing)

        let disclosure = state.selectedOffer?.renewalDisclosure
        disclosureLabel.text = disclosure
        disclosurePanel.isHidden = disclosure == nil
    }

    private func update(_ button: UIButton, title: String, showsSpinner: Bool, isDimmed: Bool) {
        button.configuration?.title = title
        button.configuration?.showsActivityIndicator = showsSpinner
        button.accessibilityLabel = title
        button.alpha = isDimmed ? 0.5 : 1
        button.accessibilityTraits = isDimmed ? [.button, .notEnabled] : .button
    }

    private func renderStatus(_ state: PaywallModel.State) {
        switch state.busy {
        case .purchasing:
            statusPanel.show("Waiting for the App Store\u{2026}", isBusy: true)
        case .restoring:
            statusPanel.show("Restoring your purchases\u{2026}", isBusy: true)
        case .idle:
            guard let notice = state.notice else {
                statusPanel.show(nil)
                return
            }
            let isFailure: Bool
            if case .failure = notice { isFailure = true } else { isFailure = false }
            statusPanel.show(PaywallModel.message(for: notice), tone: isFailure ? .error : .neutral)
        }
    }

    /// Success closes the paywall and then hands control back, so the range, the screen or the action the user wanted continues on a screen that is already visible again.
    private func finish(unlocked: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if unlocked { UIAccessibility.post(notification: .announcement, argument: "Crucible Pro is on") }
        let completion = completion
        dismiss(animated: TVMotion.animationsEnabled) { completion(unlocked) }
    }

    private func refocus() {
        view.layoutIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private static func identifier(for offer: ProOffer) -> String {
        switch offer.kind {
        case .lifetime: "paywall.offer.lifetime"
        case .annual: "paywall.offer.annual"
        }
    }

    private func makeBuyButton() -> UIButton {
        let button = TVButton.make(.primary, title: "Continue") { [weak self] in self?.model.purchaseSelected() }
        button.accessibilityIdentifier = "paywall.buy"
        return button
    }

    private func makeRestoreButton() -> UIButton {
        let button = TVButton.make(.glass, title: "Restore Purchases") { [weak self] in self?.model.restore() }
        button.accessibilityIdentifier = "paywall.restore"
        return button
    }

    private func makeDisclosurePanel() -> TVReadOnlyPanel {
        disclosureLabel.font = TVFont.cardSubtitle
        disclosureLabel.textColor = Theme.Color.labelSecondary
        disclosureLabel.numberOfLines = 0
        let panel = TVReadOnlyPanel(wrapping: disclosureLabel) { [weak self] in self?.disclosureLabel.text }
        panel.accessibilityIdentifier = "paywall.disclosure"
        panel.isHidden = true
        return panel
    }

    private func installBackdrop() {
        backdrop.setColors(
            [Theme.Color.accent.withAlphaComponent(0.14), Theme.Color.canvas],
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 0.7, y: 0.85)
        )
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func installColumns() {
        let info = TVPaywallInfoColumn(request: model.request)
        let purchase = makePurchaseColumn()
        columns.axis = .horizontal
        columns.alignment = .top
        columns.spacing = Layout.columnGap
        columns.addArrangedSubview(info)
        columns.addArrangedSubview(purchase)
        columns.translatesAutoresizingMaskIntoConstraints = false

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.clipsToBounds = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(columns)
        view.addSubview(scrollView)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safe.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            columns.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Layout.verticalInset),
            columns.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Layout.verticalInset),
            columns.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            columns.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            info.widthAnchor.constraint(equalToConstant: Layout.infoWidth),
        ])
    }

    private func makePurchaseColumn() -> UIView {
        offersStack.axis = .vertical
        offersStack.spacing = Theme.Space.s
        offersStack.alignment = .fill

        let column = UIStackView(arrangedSubviews: [statusPanel, offersStack, buyButton, restoreButton, disclosurePanel])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Space.s
        column.setCustomSpacing(Theme.Space.m, after: offersStack)
        return column
    }

    private func installStateView() {
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
