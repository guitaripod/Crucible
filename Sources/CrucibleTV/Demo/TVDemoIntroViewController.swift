import CrucibleCore
import CrucibleDesign
import UIKit

/// The first thing a person sees inside the demo: what is real and what is fictional, and the things worth trying, with one button
/// that starts exploring. Full screen and focusable; Menu starts exploring too.
final class TVDemoIntroViewController: TVDemoModalViewController {
    private lazy var startButton = makeStartButton()

    override var focusTarget: UIView? { startButton }

    override func makeLeadingColumn() -> UIView {
        let title = Self.makeTitle(DemoCopy.introTitle)
        let body = Self.makeBody(DemoCopy.introBody)
        let stack = UIStackView(arrangedSubviews: [title, body, startButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.s
        stack.setCustomSpacing(Theme.Space.l, after: body)
        return stack
    }

    override func makeTrailingColumn() -> UIView {
        TVDemoStepsPanel(steps: DemoTour.shared.steps)
    }

    private func makeStartButton() -> UIButton {
        let button = TVButton.make(.primary, title: DemoCopy.introStart) { [weak self] in self?.startExploring() }
        button.accessibilityIdentifier = "demo.intro.start"
        return button
    }

    private func startExploring() {
        dismiss(animated: TVMotion.animationsEnabled)
    }
}

/// The steps of the tour as a read-only list of symbol, name and one line, headed "Things to try". Nothing in it takes focus;
/// VoiceOver reaches it as one stop.
final class TVDemoStepsPanel: TVReadOnlyPanel {
    private static let heading = String(localized: "Things to try")

    init(steps: [DemoTourStep]) {
        super.init(frame: .zero)
        let heading = UILabel()
        heading.text = Self.heading.uppercased()
        heading.font = TVFont.eyebrow
        heading.textColor = Theme.Color.accentText
        heading.accessibilityTraits = .header

        let stack = UIStackView(arrangedSubviews: [heading] + steps.map(Self.row))
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        spokenLabel = { Self.heading + ". " + steps.map { String(localized: "\($0.title). \($0.detail)") }.joined(separator: " ") }
        accessibilityIdentifier = "demo.steps"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func row(_ step: DemoTourStep) -> UIView {
        TVSymbolRow.make(symbol: step.symbol, title: step.title, detail: step.detail)
    }
}
