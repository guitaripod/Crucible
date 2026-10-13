import CrucibleCore
import CrucibleDesign
import UIKit

/// The soft paywall at the end of the tour, shown once: what Crucible costs (nothing, with your own server), what Pro adds, and three
/// ways on. Connecting leaves the demo after a confirmation, "See Crucible Pro" opens the real paywall over this screen and closes
/// back to it, and "Keep exploring" (or Menu) simply closes. It is only offered a store to look at when the build sells Pro.
final class TVDemoFinaleViewController: TVDemoModalViewController {
    private let offersPro: Bool
    private let onConnect: @MainActor () -> Void
    private lazy var connectButton = makeConnectButton()
    private lazy var keepButton = makeKeepButton()

    init(offersPro: Bool, onConnect: @escaping @MainActor () -> Void) {
        self.offersPro = offersPro
        self.onConnect = onConnect
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var focusTarget: UIView? { connectButton }

    override func makeLeadingColumn() -> UIView {
        let stack = UIStackView(arrangedSubviews: [Self.makeTitle(DemoCopy.finaleTitle), Self.makeBody(DemoCopy.finaleBody)])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.s
        return stack
    }

    override func makeTrailingColumn() -> UIView {
        var buttons = [connectButton]
        if offersPro { buttons.append(makeProButton()) }
        buttons.append(keepButton)
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Theme.Space.s
        return stack
    }

    private func makeConnectButton() -> UIButton {
        let button = TVButton.make(.primary, title: DemoCopy.connectTitle) { [weak self] in self?.confirmConnect() }
        button.accessibilityIdentifier = "demo.finale.connect"
        return button
    }

    private func makeProButton() -> UIButton {
        let button = TVButton.make(.glass, title: DemoCopy.finalePro) { [weak self] in self?.showPaywall() }
        button.accessibilityIdentifier = "demo.finale.pro"
        return button
    }

    private func makeKeepButton() -> UIButton {
        let button = TVButton.make(.glass, title: DemoCopy.finaleKeepExploring) { [weak self] in self?.keepExploring() }
        button.accessibilityIdentifier = "demo.finale.keep"
        return button
    }

    private func confirmConnect() {
        presentLeaveDemoConfirmation(connecting: true) { [weak self] in
            self?.dismiss(animated: false) { self?.onConnect() }
        }
    }

    private func showPaywall() {
        TVPaywallViewController.present(PaywallRequest(), from: self) { _ in }
    }

    private func keepExploring() {
        dismiss(animated: TVMotion.animationsEnabled)
    }
}
