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
    private static let heading = "Things to try"

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
        spokenLabel = { Self.heading + ". " + steps.map { "\($0.title). \($0.detail)" }.joined(separator: " ") }
        accessibilityIdentifier = "demo.steps"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func row(_ step: DemoTourStep) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: step.symbol))
        icon.contentMode = .center
        icon.tintColor = Theme.Color.accentText
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.row, weight: .semibold)
        let well = UIView()
        well.backgroundColor = Theme.Color.accentTint
        well.layer.cornerRadius = Theme.Radius.s
        well.layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)

        let title = UILabel()
        title.text = step.title
        title.font = TVFont.cardTitle
        title.textColor = Theme.Color.label
        let detail = UILabel()
        detail.text = step.detail
        detail.font = TVFont.cardSubtitle
        detail.textColor = Theme.Color.labelSecondary
        detail.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs

        let row = UIStackView(arrangedSubviews: [well, text])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Space.s
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            well.heightAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        return row
    }
}
