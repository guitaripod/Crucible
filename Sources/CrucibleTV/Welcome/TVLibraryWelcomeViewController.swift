import CrucibleCore
import CrucibleDesign
import UIKit

/// The welcome a library opens with the first time on this Apple TV (a new install, or the first since the app's data was cleared):
/// which server it reached and where the viewer stands with Crucible Pro on the left, what is theirs and what Trakt would add on
/// the right. It settles in line by line and changes in place when the store or Trakt answer while it is up. Start Watching, or
/// Menu, closes it; Connect Trakt opens Trakt's pitch and code on top of it.
final class TVLibraryWelcomeViewController: TVDemoModalViewController {
    private enum Layout {
        static let glyphSide: CGFloat = 132
        static let standingWell: CGFloat = 72
        static let brandSide: CGFloat = 64
        static let listedLimit = 4
    }

    private let serverName: String
    private let glyph = CrystalGlyphView()
    private let titleLabel = TVDemoModalViewController.makeTitle(WelcomeCopy.title)
    private lazy var serverLabel = Self.makeBody(WelcomeCopy.connected(to: serverName))
    private let standingIcon = UIImageView()
    private let standingTitle = UILabel()
    private let standingMessage = TVDemoModalViewController.makeBody("")
    private lazy var standingBlock = makeStandingBlock()
    private lazy var startButton = makeStartButton()
    private lazy var proButton = makeProButton()
    private lazy var buttons = makeButtons()
    private let listPanel = TVReadOnlyPanel()
    private let list = UIStackView()
    private let traktCard = UIView()
    private let traktTitle = UILabel()
    private let traktMessage = UILabel()
    private let traktBadge = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    private lazy var traktButton = makeTraktButton()
    private var listed: [WelcomeCopy.Highlight] = []
    private var didSettleIn = false
    private var proObservation: UUID?
    private var traktObservation: UUID?

    init(serverName: String) {
        self.serverName = serverName
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let pro = proObservation, trakt = traktObservation
        Task { @MainActor in
            if let pro { ProAccess.shared.stopObserving(pro) }
            if let trakt { TraktAccount.shared.stopObserving(trakt) }
        }
    }

    override var focusTarget: UIView? { startButton }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "welcome.screen"
        render()
        proObservation = ProAccess.shared.observe { [weak self] _ in self?.render() }
        traktObservation = TraktAccount.shared.observe { [weak self] in self?.render() }
        if TVMotion.ambientAllowed { revealedViews.forEach { $0.alpha = 0 } }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        render()
        guard !didSettleIn else { return }
        didSettleIn = true
        TVMotion.stagger(revealedViews)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if TVMotion.ambientAllowed { glyph.startBreathing() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    /// The views that settle in one after another, top to bottom, left column first.
    private var revealedViews: [UIView] {
        [glyph, titleLabel, serverLabel, standingBlock, buttons, listPanel, traktCard]
    }

    override func makeLeadingColumn() -> UIView {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Layout.glyphSide),
            glyph.heightAnchor.constraint(equalToConstant: Layout.glyphSide),
        ])
        serverLabel.accessibilityIdentifier = "welcome.server"
        let stack = UIStackView(arrangedSubviews: [glyph, titleLabel, serverLabel, standingBlock, buttons])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.xs
        stack.setCustomSpacing(Theme.Space.l, after: glyph)
        stack.setCustomSpacing(Theme.Space.xl, after: serverLabel)
        stack.setCustomSpacing(Theme.Space.xl, after: standingBlock)
        return stack
    }

    override func makeTrailingColumn() -> UIView {
        list.axis = .vertical
        list.spacing = Theme.Space.m
        list.translatesAutoresizingMaskIntoConstraints = false
        listPanel.contentView.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: listPanel.contentView.topAnchor),
            list.bottomAnchor.constraint(equalTo: listPanel.contentView.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: listPanel.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: listPanel.contentView.trailingAnchor),
        ])
        listPanel.spokenLabel = { [weak self] in self?.listed.map { "\($0.title). \($0.detail)" }.joined(separator: " ") }
        listPanel.accessibilityIdentifier = "welcome.list"
        buildTraktCard()
        let stack = UIStackView(arrangedSubviews: [listPanel, traktCard])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Theme.Space.xl
        return stack
    }

    /// Lays out what the plan says now. Called again whenever the store or Trakt answer, it changes text in place and keeps the
    /// focus where it is, unless the focused button went away.
    private func render() {
        let plan = WelcomePlan.current()
        standingIcon.image = UIImage(systemName: plan.standingSymbol)
        standingTitle.text = plan.standingTitle
        standingMessage.text = plan.standingMessage
        standingBlock.accessibilityLabel = "\(plan.standingTitle). \(plan.standingMessage)"
        proButton.isHidden = !plan.offersPro
        showList(Self.listed(for: plan))
        showTrakt(plan.trakt)
        if let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView, focused.isHidden || focused.superview?.isHidden == true {
            setNeedsFocusUpdate()
        }
    }

    /// What is the viewer's to use: a few of Pro's features while everything is open, otherwise what the free app does.
    private static func listed(for plan: WelcomePlan) -> [WelcomeCopy.Highlight] {
        guard plan.listsProFeatures else { return plan.freeHighlights(includingDownloads: false) }
        return ProFeature.listed(isTV: true).prefix(Layout.listedLimit).map {
            WelcomeCopy.Highlight(symbol: $0.symbol, title: $0.title, detail: $0.summary)
        }
    }

    private func showList(_ highlights: [WelcomeCopy.Highlight]) {
        guard highlights != listed else { return }
        listed = highlights
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        highlights.forEach { list.addArrangedSubview(TVSymbolRow.make(symbol: $0.symbol, title: $0.title, detail: $0.detail)) }
    }

    private func showTrakt(_ step: WelcomePlan.TraktStep?) {
        guard let step else {
            traktCard.isHidden = true
            return
        }
        traktCard.isHidden = false
        traktTitle.text = WelcomeCopy.title(of: step)
        traktMessage.text = WelcomeCopy.message(of: step)
        let action = WelcomeCopy.action(of: step)
        traktButton.configuration?.title = action
        traktButton.accessibilityLabel = action
        traktButton.isHidden = action == nil
        traktBadge.isHidden = action != nil
        traktCard.accessibilityLabel = [traktTitle.text, traktMessage.text].compactMap { $0 }.joined(separator: ". ")
    }

    private func makeStandingBlock() -> UIView {
        standingIcon.contentMode = .center
        standingIcon.tintColor = Theme.Color.accentText
        standingIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        let well = UIView()
        well.backgroundColor = Theme.Color.accentTint
        well.layer.cornerRadius = Layout.standingWell / 2
        well.layer.cornerCurve = .continuous
        standingIcon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(standingIcon)
        well.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: Layout.standingWell),
            well.heightAnchor.constraint(equalToConstant: Layout.standingWell),
            standingIcon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            standingIcon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        standingTitle.font = Theme.Font.title3
        standingTitle.textColor = Theme.Color.label
        standingTitle.numberOfLines = 0
        standingMessage.font = TVFont.screenSummary
        let text = UIStackView(arrangedSubviews: [standingTitle, standingMessage])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs
        let block = UIStackView(arrangedSubviews: [well, text])
        block.axis = .horizontal
        block.alignment = .top
        block.spacing = Theme.Space.m
        block.isAccessibilityElement = true
        block.accessibilityIdentifier = "welcome.standing"
        return block
    }

    private func makeButtons() -> UIView {
        let stack = UIStackView(arrangedSubviews: [startButton, proButton])
        stack.axis = .horizontal
        stack.spacing = Theme.Space.m
        return stack
    }

    private func makeStartButton() -> UIButton {
        let button = TVButton.make(.primary, title: WelcomeCopy.start, symbol: "play.fill") { [weak self] in self?.startWatching() }
        button.accessibilityIdentifier = "welcome.start"
        return button
    }

    private func makeProButton() -> UIButton {
        let button = TVButton.make(.glass, title: WelcomeCopy.seePro) { ProAccess.shared.requestUnlock(nil) }
        button.accessibilityIdentifier = "welcome.pro"
        return button
    }

    private func makeTraktButton() -> UIButton {
        let button = TVButton.make(.glass, title: TraktCopy.connect, symbol: "link") { [weak self] in self?.openTrakt() }
        button.accessibilityIdentifier = "welcome.trakt"
        return button
    }

    private func buildTraktCard() {
        let mark = UIImageView(image: BrandMark.trakt.image)
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        traktTitle.font = Theme.Font.title3
        traktTitle.textColor = Theme.Color.label
        traktTitle.numberOfLines = 0
        traktMessage.font = TVFont.cardSubtitle
        traktMessage.textColor = Theme.Color.labelSecondary
        traktMessage.numberOfLines = 0
        traktBadge.tintColor = Theme.Color.statusOK
        traktBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        traktBadge.setContentHuggingPriority(.required, for: .horizontal)
        let titleLine = UIStackView(arrangedSubviews: [traktTitle, traktBadge])
        titleLine.axis = .horizontal
        titleLine.alignment = .center
        titleLine.spacing = Theme.Space.xs
        let text = UIStackView(arrangedSubviews: [titleLine, traktMessage])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = Theme.Space.xxs
        let header = UIStackView(arrangedSubviews: [mark, text])
        header.axis = .horizontal
        header.alignment = .top
        header.spacing = Theme.Space.m
        let stack = UIStackView(arrangedSubviews: [header, traktButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        traktCard.backgroundColor = Theme.Color.surface.withAlphaComponent(0.72)
        traktCard.layer.cornerRadius = Theme.Radius.l
        traktCard.layer.cornerCurve = .continuous
        traktCard.accessibilityIdentifier = "welcome.traktCard"
        traktCard.addSubview(stack)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: Layout.brandSide),
            mark.heightAnchor.constraint(equalToConstant: Layout.brandSide),
            stack.topAnchor.constraint(equalTo: traktCard.topAnchor, constant: Theme.Space.l),
            stack.bottomAnchor.constraint(equalTo: traktCard.bottomAnchor, constant: -Theme.Space.l),
            stack.leadingAnchor.constraint(equalTo: traktCard.leadingAnchor, constant: Theme.Space.l),
            stack.trailingAnchor.constraint(equalTo: traktCard.trailingAnchor, constant: -Theme.Space.l),
        ])
    }

    private func startWatching() {
        presentingViewController?.dismiss(animated: TVMotion.animationsEnabled)
    }

    private func openTrakt() {
        TVNavigation.push(TVTraktSettingsViewController(), from: self)
    }
}
