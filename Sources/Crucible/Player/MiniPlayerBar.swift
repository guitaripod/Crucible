import AVFoundation
import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The compact player docked above the tab bar: the live picture, what is playing, play or pause and close. Tapping it or
/// swiping it up opens the full player again. Above a minimized tab bar it keeps only the picture, the title and play or pause.
@MainActor
final class MiniPlayerBar: UIView {
    var onExpand: (() -> Void)?
    var onClose: (() -> Void)?

    /// Whether the bar shows the picture. The full player clears it while it is on screen, so only one surface draws the video.
    var isLive = false {
        didSet { attachPicture() }
    }

    private let video = PlayerLayerView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progress = ProgressBar()
    private let info = UIView()
    private let playPause = UIButton(configuration: .plain())
    private let closeButton = UIButton(configuration: .plain())
    private weak var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var sceneObservers: [any NSObjectProtocol] = []
    private var isInForeground = true
    private var duration: Double = 0
    private var regularVideoHeight: NSLayoutConstraint?
    private var inlineVideoHeight: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "miniPlayer"
        buildLayout()
        configureButtons()
        configureGestures()
        if #available(iOS 26.0, *) {
            registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) { (bar: MiniPlayerBar, _: UITraitCollection) in
                bar.applyEnvironment()
            }
        }
        applyEnvironment()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Follows `player`: its picture while live and its play or pause state. The picture leaves the player while `scene` is in the
    /// background, which is what lets the sound play on there.
    func attach(player: AVPlayer, scene: UIWindowScene?) {
        self.player = player
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] observed, _ in
            let paused = observed.timeControlStatus == .paused
            Task { @MainActor in self?.showPaused(paused) }
        }
        observe(scene)
        attachPicture()
    }

    func detach() {
        statusObservation = nil
        sceneObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sceneObservers.removeAll()
        video.playerLayer.player = nil
        player = nil
    }

    func configure(title: String, subtitle: String?, duration: Double) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        self.duration = duration
        info.accessibilityLabel = [String(localized: "Now Playing"), title, subtitle].compactMap { $0 }.joined(separator: ", ")
        applyEnvironment()
    }

    func showPosition(_ seconds: Double) {
        guard duration > 0 else { return }
        progress.progress = min(1, max(0, seconds / duration))
    }

    private func observe(_ scene: UIWindowScene?) {
        guard sceneObservers.isEmpty else { return }
        isInForeground = scene.map { $0.activationState != .background } ?? true
        let center = NotificationCenter.default
        sceneObservers = [
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(false) }
            },
            center.addObserver(forName: UIScene.willEnterForegroundNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(true) }
            },
        ]
    }

    private func setForeground(_ foreground: Bool) {
        isInForeground = foreground
        attachPicture()
    }

    private func attachPicture() {
        let shown = isLive && isInForeground ? player : nil
        guard video.playerLayer.player !== shown else { return }
        video.playerLayer.player = shown
    }

    private func showPaused(_ paused: Bool) {
        playPause.configuration?.image = UIImage(systemName: paused ? "play.fill" : "pause.fill")
        playPause.accessibilityLabel = paused ? String(localized: "Play") : String(localized: "Pause")
    }

    private func buildLayout() {
        video.translatesAutoresizingMaskIntoConstraints = false
        video.backgroundColor = .black
        video.layer.cornerRadius = 6
        video.layer.cornerCurve = .continuous
        video.clipsToBounds = true
        video.playerLayer.videoGravity = .resizeAspectFill

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        progress.style = .onSurface
        progress.translatesAutoresizingMaskIntoConstraints = false

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, progress])
        labels.axis = .vertical
        labels.spacing = 2
        labels.setCustomSpacing(4, after: subtitleLabel)

        let infoRow = UIStackView(arrangedSubviews: [video, labels])
        infoRow.alignment = .center
        infoRow.spacing = 10
        infoRow.isUserInteractionEnabled = false
        infoRow.translatesAutoresizingMaskIntoConstraints = false
        info.addSubview(infoRow)
        info.isAccessibilityElement = true
        info.accessibilityTraits = .button
        info.accessibilityHint = String(localized: "Opens the player")
        info.accessibilityIdentifier = "miniPlayer.expand"

        let row = UIStackView(arrangedSubviews: [info, playPause, closeButton])
        row.alignment = .center
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [playPause, closeButton].forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let regular = video.heightAnchor.constraint(equalToConstant: 32)
        let inline = video.heightAnchor.constraint(equalToConstant: 24)
        regularVideoHeight = regular
        inlineVideoHeight = inline
        NSLayoutConstraint.activate([
            regular,
            video.widthAnchor.constraint(equalTo: video.heightAnchor, multiplier: 16.0 / 9.0),
            progress.heightAnchor.constraint(equalToConstant: 3),
            infoRow.leadingAnchor.constraint(equalTo: info.leadingAnchor),
            infoRow.trailingAnchor.constraint(equalTo: info.trailingAnchor),
            infoRow.topAnchor.constraint(equalTo: info.topAnchor),
            infoRow.bottomAnchor.constraint(equalTo: info.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        accessibilityElements = [info, playPause, closeButton]
    }

    private func configureButtons() {
        playPause.configuration = Self.buttonConfiguration(symbol: "pause.fill", size: 18)
        playPause.accessibilityIdentifier = "miniPlayer.playPause"
        playPause.accessibilityLabel = String(localized: "Pause")
        playPause.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .primaryActionTriggered)

        closeButton.configuration = Self.buttonConfiguration(symbol: "xmark", size: 15)
        closeButton.accessibilityIdentifier = "miniPlayer.close"
        closeButton.accessibilityLabel = String(localized: "Close Player")
        closeButton.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.onClose?()
        }, for: .primaryActionTriggered)
    }

    private static func buttonConfiguration(symbol: String, size: CGFloat) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9)
        return configuration
    }

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: nil, action: nil)
        tap.addTarget(self, action: #selector(expandFromGesture))
        addGestureRecognizer(tap)
        let swipe = UISwipeGestureRecognizer(target: nil, action: nil)
        swipe.direction = .up
        swipe.addTarget(self, action: #selector(expandFromGesture))
        addGestureRecognizer(swipe)
    }

    /// Gesture recognizers have no closure-based initializer, so a tap or upward swipe reaches the bar through this selector.
    @objc private func expandFromGesture() {
        Haptics.light()
        onExpand?()
    }

    private func togglePlayback() {
        guard let player else { return }
        Haptics.light()
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    /// Above a minimized tab bar the accessory is a small capsule, so the bar drops to the picture, the title and play or pause.
    private func applyEnvironment() {
        var isInline = false
        if #available(iOS 26.0, *) {
            isInline = traitCollection.tabAccessoryEnvironment == .inline
        }
        subtitleLabel.isHidden = isInline || (subtitleLabel.text ?? "").isEmpty
        progress.isHidden = isInline || duration <= 0
        closeButton.isHidden = isInline
        regularVideoHeight?.isActive = !isInline
        inlineVideoHeight?.isActive = isInline
    }
}

/// A view whose own layer draws a player's picture.
private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else { fatalError("PlayerLayerView is backed by an AVPlayerLayer") }
        return layer
    }
}
