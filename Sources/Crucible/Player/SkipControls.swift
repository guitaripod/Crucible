@preconcurrency import UIKit

/// Shared glass-capsule construction for the floating player controls.
@MainActor
private func makeCapsuleGlass(height: CGFloat) -> UIVisualEffectView {
    let glass = Glass.effectView(fallback: .systemThinMaterialDark, interactive: true)
    glass.clipsToBounds = true
    glass.translatesAutoresizingMaskIntoConstraints = false
    if #available(iOS 26.0, tvOS 26.0, *) {
        glass.cornerConfiguration = .capsule()
    } else {
        glass.layer.cornerRadius = height / 2
        glass.layer.cornerCurve = .continuous
    }
    return glass
}

/// Fades a floating control out and removes it, or removes it at once under Reduce Motion.
@MainActor
private func fadeOutAndRemove(_ view: UIView, animated: Bool) {
    guard animated, !UIAccessibility.isReduceMotionEnabled else {
        view.removeFromSuperview()
        return
    }
    UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState) {
        view.alpha = 0
    } completion: { _ in
        view.removeFromSuperview()
    }
}

/// Fades a floating control in unless Reduce Motion is on.
@MainActor
private func fadeIn(_ view: UIView) {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    view.alpha = 0
    UIView.animate(withDuration: 0.25) { view.alpha = 1 }
}

/// Pins a floating control bottom-right above the system transport controls.
@MainActor
private func anchorAboveTransport(_ view: UIView, in host: UIView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -28),
        view.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -84),
    ])
}

/// The Skip Intro / Skip Credits control: a 48pt glass capsule whose ember fill sweeps left to
/// right in proportion to the elapsed marker time.
@MainActor
final class SkipPillView: UIView {
    static let height: CGFloat = 48

    private let glass = makeCapsuleGlass(height: SkipPillView.height)
    private let fill = UIView()
    private let button = UIButton(configuration: .plain())
    private var progress: CGFloat = 0
    private var isRemoving = false
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        fill.backgroundColor = Theme.Color.accent.withAlphaComponent(0.42)
        fill.isUserInteractionEnabled = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "forward.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.baseForegroundColor = Theme.Color.onArt
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.buttonLabel
            return outgoing
        }
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)

        addSubview(glass)
        glass.contentView.addSubview(fill)
        addSubview(button)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFill()
    }

    /// Updates the label and sweep. The sweep glides between the once-a-second updates unless
    /// Reduce Motion is on.
    func update(title: String, accessibilityTitle: String, progress newProgress: Double) {
        button.configuration?.title = title
        button.accessibilityLabel = accessibilityTitle
        let clamped = CGFloat(min(max(newProgress, 0), 1))
        guard clamped != progress else { return }
        progress = clamped
        if UIAccessibility.isReduceMotionEnabled || window == nil {
            applyFill()
        } else {
            UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                self.applyFill()
            }
        }
    }

    private func applyFill() {
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }

    func present(in host: UIView) {
        anchorAboveTransport(self, in: host)
        fadeIn(self)
    }

    func dismiss(animated: Bool) {
        guard !isRemoving else { return }
        isRemoving = true
        fadeOutAndRemove(self, animated: animated)
    }
}

/// The brief "Skipped intro" confirmation with an Undo action.
@MainActor
final class SkipToastView: UIView {
    static let visibleDuration: Duration = .seconds(4)

    private let glass = makeCapsuleGlass(height: SkipPillView.height)
    private var dismissTask: Task<Void, Never>?
    private var isRemoving = false
    private let onUndo: () -> Void
    private let onExpire: () -> Void

    init(message: String, onUndo: @escaping () -> Void, onExpire: @escaping () -> Void) {
        self.onUndo = onUndo
        self.onExpire = onExpire
        super.init(frame: .zero)
        build(message: message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { dismissTask?.cancel() }

    private func build(message: String) {
        let label = UILabel()
        label.text = message
        label.font = Theme.Font.subheadlineSemibold
        label.textColor = Theme.Color.onArt
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)

        var config = UIButton.Configuration.plain()
        config.title = "Undo"
        config.baseForegroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.subheadlineSemibold
            return outgoing
        }
        let undo = UIButton(configuration: config)
        undo.accessibilityLabel = "Undo skip"
        undo.addAction(UIAction { [weak self] _ in self?.undoTapped() }, for: .primaryActionTriggered)
        undo.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let row = UIStackView(arrangedSubviews: [label, undo])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 8)
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glass)
        addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        accessibilityElements = [label, undo]
    }

    private func undoTapped() {
        dismissTask?.cancel()
        onUndo()
    }

    func present(in host: UIView) {
        anchorAboveTransport(self, in: host)
        fadeIn(self)
        UIAccessibility.post(notification: .announcement, argument: "Skipped intro. Undo available.")
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled, let self else { return }
            self.onExpire()
        }
    }

    func dismiss(animated: Bool) {
        guard !isRemoving else { return }
        isRemoving = true
        dismissTask?.cancel()
        fadeOutAndRemove(self, animated: animated)
    }
}
