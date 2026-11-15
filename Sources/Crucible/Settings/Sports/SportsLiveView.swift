import CrucibleCore
import CrucibleDesign
import UIKit

/// The research at work: the file, the model, the time it has taken, and its newest steps arriving one by one.
struct SportsLiveConfiguration: UIContentConfiguration {
    var phase: String
    var name: String
    var file: String
    var posterPath: String?
    var kind: SportsKind = .sports
    var model: String?
    var elapsed: Int
    var receivedAt: Date
    var steps: [SportsLiveStep]
    var waiting: String?
    var lastLooked: String?

    func makeContentView() -> UIView & UIContentView { SportsLiveView(configuration: self) }
    func updated(for state: UIConfigurationState) -> SportsLiveConfiguration { self }
}

final class SportsLiveView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private static let stepsShown = 5
    private let card = UIView()
    private let dot = UIView()
    private let phaseLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let poster = SportsPosterView()
    private let nameLabel = UILabel()
    private let fileLabel = UILabel()
    private let modelLabel = UILabel()
    private let timeline = UIStackView()
    private let footerLabel = UILabel()
    private var shownStepIDs: [Int] = []
    private var timer: Timer?

    init(configuration: SportsLiveConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        dot.layer.removeAllAnimations()
        guard window != nil else { return }
        pulseDot()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func build() {
        card.backgroundColor = Theme.Color.surface
        card.layer.cornerRadius = Theme.Radius.l
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.Color.accent.withAlphaComponent(0.55).cgColor
        dot.backgroundColor = Theme.Color.accent
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        phaseLabel.font = Theme.Font.headline
        phaseLabel.adjustsFontForContentSizeCategory = true
        phaseLabel.textColor = Theme.Color.label
        phaseLabel.numberOfLines = 0
        elapsedLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.textColor = Theme.Color.labelSecondary
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [dot, phaseLabel, elapsedLabel])
        header.alignment = .center
        header.spacing = Theme.Space.xs
        nameLabel.font = Theme.Font.title3
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 2
        fileLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        fileLabel.adjustsFontForContentSizeCategory = true
        fileLabel.textColor = Theme.Color.labelTertiary
        fileLabel.numberOfLines = 2
        fileLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.font = Theme.Font.footnote
        modelLabel.adjustsFontForContentSizeCategory = true
        modelLabel.textColor = Theme.Color.labelSecondary
        modelLabel.numberOfLines = 1
        modelLabel.lineBreakMode = .byTruncatingMiddle
        let names = UIStackView(arrangedSubviews: [nameLabel, fileLabel, modelLabel])
        names.axis = .vertical
        names.spacing = Theme.Space.xxs
        let body = UIStackView(arrangedSubviews: [poster, names])
        body.alignment = .top
        body.spacing = Theme.Space.s
        timeline.axis = .vertical
        timeline.spacing = Theme.Space.xs
        footerLabel.font = Theme.Font.footnote
        footerLabel.adjustsFontForContentSizeCategory = true
        footerLabel.textColor = Theme.Color.labelSecondary
        footerLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [header, body, timeline, footerLabel])
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        for view in [card, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(card)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Space.m),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            poster.widthAnchor.constraint(equalToConstant: 56),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: Theme.Size.posterAspect),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    private func apply() {
        guard let configuration = configuration as? SportsLiveConfiguration else { return }
        phaseLabel.text = configuration.phase
        nameLabel.text = configuration.name
        fileLabel.text = configuration.file
        fileLabel.isHidden = configuration.file.isEmpty || configuration.file == configuration.name
        modelLabel.text = configuration.model.map(SportsCopy.model)
        modelLabel.isHidden = configuration.model == nil
        poster.show(path: configuration.posterPath, width: 56, kind: configuration.kind)
        let footer = [configuration.waiting, configuration.lastLooked].compactMap { $0 }
        footerLabel.text = footer.joined(separator: " · ")
        footerLabel.isHidden = footer.isEmpty
        accessibilityLabel = "\(SportsCopy.liveNow), \(configuration.name)"
        tick()
        showSteps(configuration.steps)
    }

    private func tick() {
        guard let configuration = configuration as? SportsLiveConfiguration else { return }
        let seconds = configuration.elapsed + Int(Date().timeIntervalSince(configuration.receivedAt))
        elapsedLabel.text = SportsCopy.duration(seconds)
        let newest = configuration.steps.first.map(SportsCopy.step) ?? configuration.phase
        accessibilityValue = "\(newest), \(SportsCopy.elapsed(seconds))"
    }

    /// Rebuilds the timeline, sliding in only the steps that are new since the last time it was shown.
    private func showSteps(_ steps: [SportsLiveStep]) {
        let shown = Array(steps.prefix(Self.stepsShown))
        let ids = shown.map(\.id)
        guard ids != shownStepIDs else { return }
        let fresh = Set(ids).subtracting(shownStepIDs)
        let animate = !shownStepIDs.isEmpty && !UIAccessibility.isReduceMotionEnabled
        shownStepIDs = ids
        timeline.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, step) in shown.enumerated() {
            let row = stepRow(step, isNewest: index == 0)
            timeline.addArrangedSubview(row)
            if animate && fresh.contains(step.id) {
                row.alpha = 0
                row.transform = CGAffineTransform(translationX: 0, y: -8)
                UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                    row.alpha = 1
                    row.transform = .identity
                }
            }
        }
    }

    private func stepRow(_ step: SportsLiveStep, isNewest: Bool) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: SportsCopy.stepSymbol(step.kind)))
        icon.tintColor = isNewest ? Theme.Color.accentText : Theme.Color.labelTertiary
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let label = UILabel()
        label.text = SportsCopy.step(step)
        label.font = isNewest ? Theme.Font.subheadlineSemibold : Theme.Font.subheadline
        label.adjustsFontForContentSizeCategory = true
        label.textColor = isNewest ? Theme.Color.label : Theme.Color.labelSecondary
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.alignment = .center
        row.spacing = Theme.Space.xs
        return row
    }

    private func pulseDot() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.25
        breathe.duration = 0.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        dot.layer.add(breathe, forKey: "pulse")
    }
}
