@preconcurrency import UIKit

@MainActor
final class UpNextOverlayView: UIView {
    private let countdownLabel = UILabel()
    private let countdownSeconds: Int
    private let onPlayNext: () -> Void
    private let onDismiss: () -> Void
    private var countdownTask: Task<Void, Never>?
    private var didFinish = false

    init(
        episodeCode: String?,
        episodeTitle: String,
        countdownSeconds: Int = 10,
        onPlayNext: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.countdownSeconds = countdownSeconds
        self.onPlayNext = onPlayNext
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        build(episodeCode: episodeCode, episodeTitle: episodeTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { countdownTask?.cancel() }

    func startCountdown() {
        countdownTask = Task { [weak self] in
            guard let self else { return }
            var remaining = self.countdownSeconds
            while remaining > 0 {
                self.countdownLabel.text = "Playing in \(remaining)s"
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                remaining -= 1
            }
            self.finish(play: true)
        }
    }

    private func build(episodeCode: String?, episodeTitle: String) {
        tintColor = .systemOrange

        let blur = Glass.effectView(fallback: .systemThinMaterialDark, interactive: true)
        Glass.concentricCorners(blur, fallbackRadius: 16)
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        let header = UILabel()
        header.text = "UP NEXT"
        header.font = .systemFont(ofSize: 12, weight: .heavy)
        header.textColor = .systemOrange

        let titleLabel = UILabel()
        var parts = [String]()
        if let episodeCode { parts.append(episodeCode) }
        parts.append(episodeTitle)
        titleLabel.text = parts.joined(separator: " — ")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        countdownLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countdownLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        countdownLabel.text = "Playing in \(countdownSeconds)s"

        var dismissConfig = Glass.clearGlassButton {
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .large
            return config
        }
        dismissConfig.title = "Dismiss"
        let dismissButton = UIButton(configuration: dismissConfig)
        dismissButton.addAction(UIAction { [weak self] _ in self?.finish(play: false) }, for: .touchUpInside)

        var playConfig = Glass.prominentButton {
            var config = UIButton.Configuration.filled()
            config.cornerStyle = .large
            config.baseBackgroundColor = .systemOrange
            config.baseForegroundColor = .white
            return config
        }
        playConfig.title = "Play Now"
        playConfig.image = UIImage(systemName: "play.fill")
        playConfig.imagePadding = 8
        let playButton = UIButton(configuration: playConfig)
        playButton.addAction(UIAction { [weak self] _ in self?.finish(play: true) }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [dismissButton, playButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [header, titleLabel, countdownLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(14, after: countdownLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(blur)
        blur.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -16),
        ])
    }

    private func finish(play: Bool) {
        guard !didFinish else { return }
        didFinish = true
        countdownTask?.cancel()
        countdownTask = nil
        if play { onPlayNext() } else { onDismiss() }
    }
}
