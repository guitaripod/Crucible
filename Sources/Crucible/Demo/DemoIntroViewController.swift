import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The one-screen welcome shown the first time the demo opens: what is real, what is fictional, and the things worth trying.
final class DemoIntroViewController: DemoSheetViewController {
    init() {
        super.init(detents: [.large()])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addHeader(title: DemoCopy.introTitle, body: DemoCopy.introBody)
        contentStack.addArrangedSubview(makeLabel(DemoPhoneCopy.introReal, font: Theme.Font.callout, color: Theme.Color.labelSecondary, alignment: .center))

        let heading = makeLabel(DemoPhoneCopy.thingsToTry, font: Theme.Font.footnoteSemibold, color: Theme.Color.labelSecondary)
        heading.text = DemoPhoneCopy.thingsToTry.uppercased()
        heading.accessibilityLabel = DemoPhoneCopy.thingsToTry
        heading.accessibilityTraits = .header
        let headingRow = UIStackView(arrangedSubviews: [heading])
        headingRow.isLayoutMarginsRelativeArrangement = true
        headingRow.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        contentStack.addArrangedSubview(headingRow)
        contentStack.setCustomSpacing(6, after: headingRow)

        let steps = UIStackView(arrangedSubviews: DemoTour.shared.steps.map { DemoStepRowView(step: $0) })
        steps.axis = .vertical
        steps.spacing = 2
        contentStack.addArrangedSubview(steps)

        let start = ThemeButton.primary(title: DemoCopy.introStart)
        start.accessibilityIdentifier = "demo.intro.start"
        start.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.dismiss(animated: true)
        }, for: .primaryActionTriggered)
        addAction(start)
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }
}
