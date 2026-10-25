import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The soft paywall that closes the tour: what the app is free for, what Pro adds, and three ways on. It is a sheet the user can swipe
/// away, so nothing about it blocks the demo.
final class DemoFinaleViewController: DemoSheetViewController {
    var onConnect: (() -> Void)?

    init() {
        super.init(detents: [.medium(), .large()])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addHeader(title: DemoCopy.finaleTitle, body: DemoCopy.finaleBody)

        let connect = ThemeButton.primary(title: DemoCopy.connectTitle)
        connect.addAction(UIAction { [weak self] _ in self?.onConnect?() }, for: .primaryActionTriggered)
        addAction(connect)

        var pro = ThemeButton.glassConfiguration(title: DemoCopy.finalePro, symbol: "sparkles")
        pro.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let proButton = UIButton(configuration: pro)
        proButton.isPointerInteractionEnabled = true
        proButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.primaryButtonHeight).isActive = true
        proButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            PaywallPresenter.showOffer(from: self)
        }, for: .primaryActionTriggered)
        addAction(proButton)

        let keepExploring = makeLinkButton(title: DemoCopy.finaleKeepExploring) { [weak self] in
            self?.dismiss(animated: true)
        }
        keepExploring.accessibilityIdentifier = "demo.finale.keep"
        addAction(keepExploring)
        actionStack.spacing = 8
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }
}
