import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Says that the first finished film or episode began the Pro Week: what it opens, until when, and that nothing is charged. It sells
/// nothing, so it has no price and no buy button, only a way back to the app.
final class ProWeekStartViewController: DemoSheetViewController {
    private let endsAt: Date
    private var didCelebrate = false

    init(endsAt: Date) {
        self.endsAt = endsAt
        super.init(detents: [.large()])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let date = ProWeek.endDateText(endsAt)
        addHeader(
            title: String(localized: "Crucible Pro is yours for a week"),
            body: String(localized: "Everything in Pro is open until \(date). Nothing is charged and nothing renews; titles you download stay on this iPhone.")
        )

        let features = UIStackView(arrangedSubviews: ProFeature.listed(isTV: false).map { PaywallFeatureRowView(feature: $0, summary: $0.summary, isHighlighted: false) })
        features.axis = .vertical
        features.spacing = 2
        contentStack.addArrangedSubview(features)

        let done = ThemeButton.primary(title: String(localized: "Start the Week"))
        done.accessibilityIdentifier = "proWeek.start"
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        addAction(done)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didCelebrate else { return }
        didCelebrate = true
        Haptics.success()
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }
}
