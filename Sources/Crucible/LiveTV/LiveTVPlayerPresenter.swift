import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import MidgarCore
@preconcurrency import UIKit

/// The live channel player on the iPhone and the iPad: the system player (Picture in Picture, AirPlay, the live edge) with a
/// glass column on the trailing edge for channel up and down and a Channels menu (Previous Channel, favourites, recent,
/// the channels around this one). A banner says which channel and what is on whenever it changes. The presenter lives as
/// long as the picture does, in Picture in Picture too.
@MainActor
final class LiveTVPlayerPresenter: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private static var active: LiveTVPlayerPresenter?

    private let playback: LiveTVPlayback
    private let playerController = AVPlayerViewController()
    private let controls = LiveChannelControls()
    private let banner = LiveChannelBanner()
    private weak var host: UIViewController?
    private var isInPictureInPicture = false

    private init(channel: LiveChannel, guide: LiveTVGuide) {
        playback = LiveTVPlayback(channel: channel, guide: guide)
        super.init()
    }

    /// Plays `channel` full screen over `host`; with a live player already up, it changes channel instead.
    static func present(channel: LiveChannel, guide: LiveTVGuide, from host: UIViewController) {
        if let active, active.playerController.presentingViewController != nil || active.isInPictureInPicture {
            active.playback.tune(channel)
            return
        }
        active?.stop()
        let presenter = LiveTVPlayerPresenter(channel: channel, guide: guide)
        active = presenter
        presenter.show(from: host)
    }

    private func show(from host: UIViewController) {
        self.host = host
        playerController.player = playback.player
        playerController.delegate = self
        playerController.allowsPictureInPicturePlayback = true
        playerController.canStartPictureInPictureAutomaticallyFromInline = true
        playerController.modalPresentationStyle = .fullScreen
        playerController.updatesNowPlayingInfoCenter = false
        playerController.view.accessibilityIdentifier = "livetv.player"
        playerController.loadViewIfNeeded()
        if let overlay = playerController.contentOverlayView {
            controls.install(in: overlay, listeningOn: playerController.view)
            banner.install(in: overlay)
        }
        controls.onZap = { [weak self] offset in self?.playback.zap(by: offset) }
        controls.makeMenu = { [weak self] in self?.channelsMenu() ?? UIMenu() }
        playback.onChannel = { [weak self] channel in
            guard let self else { return }
            self.banner.show(channel: channel, program: self.playback.guide?.nowAndNext(channel.id).now)
            self.controls.refreshMenu()
        }
        playback.onFailure = { [weak self] message in self?.showFailure(message) }
        host.present(playerController, animated: true) { [weak self] in self?.playback.start() }
    }

    private func channelsMenu() -> UIMenu {
        guard let guide = playback.guide else { return UIMenu() }
        let current = playback.channel
        func action(_ channel: LiveChannel) -> UIAction {
            let program = guide.nowAndNext(channel.id).now
            let action = UIAction(title: channel.numberedTitle, state: channel.id == current.id ? .on : .off) { [weak self] _ in self?.playback.tune(channel) }
            action.subtitle = program?.title
            return action
        }
        var children: [UIMenuElement] = []
        if let previous = playback.previous {
            children.append(UIAction(title: LiveTVCopy.previousChannel, image: UIImage(systemName: "arrow.uturn.backward"), handler: { [weak self] _ in
                self?.playback.previousChannel()
            }).withSubtitle(previous.numberedTitle))
        }
        let favorites = LiveTVPreferences.favorites.compactMap(guide.channel(id:))
        if !favorites.isEmpty { children.append(UIMenu(title: LiveTVCopy.favorites, image: UIImage(systemName: "star"), children: favorites.map(action))) }
        let recent = LiveTVPreferences.recentChannels.compactMap(guide.channel(id:)).filter { $0.id != current.id }.prefix(8)
        if !recent.isEmpty { children.append(UIMenu(title: LiveTVCopy.recent, image: UIImage(systemName: "clock.arrow.circlepath"), children: recent.map(action))) }
        let nearby = (-5...5).compactMap { guide.channel(from: current.id, offset: $0) }
        var seen = Set<String>()
        children.append(UIMenu(title: LiveTVCopy.channels, options: .displayInline, children: nearby.filter { seen.insert($0.id).inserted }.map(action)))
        return UIMenu(title: current.numberedTitle, children: children)
    }

    private func showFailure(_ message: String) {
        let alert = UIAlertController(title: LiveTVCopy.failedTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: LiveTVCopy.tryAgain, style: .default) { [weak self] _ in
            guard let self else { return }
            self.playback.tune(self.playback.channel)
        })
        alert.addAction(UIAlertAction(title: LiveTVCopy.channelUp, style: .default) { [weak self] _ in self?.playback.zap(by: 1) })
        alert.addAction(UIAlertAction(title: String(localized: "Close"), style: .cancel) { [weak self] _ in
            self?.playerController.dismiss(animated: true)
            self?.stop()
        })
        playerController.present(alert, animated: true)
    }

    private func stop() {
        playback.stop()
        if Self.active === self { Self.active = nil }
    }

    // MARK: AVPlayerViewControllerDelegate

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, !context.isCancelled, !self.isInPictureInPicture else { return }
            self.stop()
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPictureInPicture = false
        if playerViewController.presentingViewController == nil { stop() }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard playerViewController.presentingViewController == nil, let host = host ?? UIApplication.shared.topViewController else {
            completionHandler(true)
            return
        }
        host.present(playerViewController, animated: true) { completionHandler(true) }
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { true }
}

extension UIAction {
    fileprivate func withSubtitle(_ text: String) -> UIAction {
        subtitle = text
        return self
    }
}

extension UIApplication {
    /// The view controller on top of the key window, for restoring a player from Picture in Picture after its host is gone.
    fileprivate var topViewController: UIViewController? {
        let window = connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// The glass column on the player's trailing edge: channel up, the Channels menu and channel down. It shows with a tap on
/// the picture, like the system's controls, and fades a few seconds later; with VoiceOver on it stays.
@MainActor
final class LiveChannelControls: NSObject, UIGestureRecognizerDelegate {
    var onZap: ((Int) -> Void)?
    var makeMenu: (() -> UIMenu)?
    private let glass = Glass.effectView(fallback: .systemThinMaterialDark, interactive: true)
    private let menuButton = UIButton(configuration: .plain())
    private var hideTask: Task<Void, Never>?

    func install(in host: UIView, listeningOn playerView: UIView) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 26
        let up = button(symbol: "chevron.up", label: LiveTVCopy.channelUp, identifier: "livetv.channelUp") { [weak self] in self?.onZap?(1) }
        let down = button(symbol: "chevron.down", label: LiveTVCopy.channelDown, identifier: "livetv.channelDown") { [weak self] in self?.onZap?(-1) }
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "list.bullet", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        configuration.baseForegroundColor = .white
        menuButton.configuration = configuration
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = LiveTVCopy.channels
        menuButton.accessibilityIdentifier = "livetv.channels"
        menuButton.isPointerInteractionEnabled = true
        menuButton.addAction(UIAction { [weak self] _ in self?.keepVisible() }, for: .menuActionTriggered)
        refreshMenu()
        let stack = UIStackView(arrangedSubviews: [up, menuButton, down])
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        host.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 52),
            glass.heightAnchor.constraint(equalToConstant: 156),
            glass.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            glass.centerYAnchor.constraint(equalTo: host.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        let tap = UITapGestureRecognizer(target: nil, action: nil)
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tap.addTarget(self, action: #selector(pictureTapped))
        playerView.addGestureRecognizer(tap)
        keepVisible()
    }

    func refreshMenu() {
        menuButton.menu = makeMenu?()
    }

    private func button(symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            Haptics.selection()
            action()
            self?.keepVisible()
        })
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.isPointerInteractionEnabled = true
        return button
    }

    @objc private func pictureTapped() {
        if glass.alpha < 0.5 { keepVisible() } else { hide() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view?.isDescendant(of: glass) ?? false)
    }

    private func keepVisible() {
        refreshMenu()
        UIView.animate(withDuration: 0.2) { self.glass.alpha = 1 }
        hideTask?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        UIView.animate(withDuration: 0.3) { self.glass.alpha = 0 }
    }
}

/// The banner at the top of the picture that says which channel is on and what airs, for a few seconds after a change.
@MainActor
final class LiveChannelBanner {
    private let glass = Glass.effectView(fallback: .systemThinMaterialDark, interactive: false)
    private let channel = UILabel()
    private let title = UILabel()
    private var hideTask: Task<Void, Never>?

    func install(in host: UIView) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 18
        glass.alpha = 0
        glass.isUserInteractionEnabled = false
        channel.font = Theme.Font.caption1
        channel.textColor = Theme.Color.emberEyebrow
        title.font = Theme.Font.headline
        title.textColor = .white
        let stack = UIStackView(arrangedSubviews: [channel, title])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        host.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 56),
            glass.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            glass.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -18),
        ])
    }

    func show(channel: LiveChannel, program: LiveProgram?) {
        self.channel.text = channel.numberedTitle
        title.text = program?.title ?? channel.title
        UIAccessibility.post(notification: .announcement, argument: [channel.numberedTitle, program?.title].compactMap { $0 }.joined(separator: ", "))
        UIView.animate(withDuration: 0.25) { self.glass.alpha = 1 }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: 0.4) { self.glass.alpha = 0 }
        }
    }
}
