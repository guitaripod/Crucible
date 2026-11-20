import AVFoundation
import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The player of one window and the bar it shrinks into. A player swiped down keeps playing in the bar above the tab bar (the tab
/// bar's Liquid Glass bottom accessory on iOS 26, a floating bar of its own before), so the viewer can browse and open it again; its
/// close button ends playback instead. The dock holds the window's player for as long as it plays, docked or full screen, because
/// the screen that started it may be gone by then.
@MainActor
final class MiniPlayerDock {
    private unowned let tabBar: TabBarController
    private(set) var active: PlayerCoordinator?
    private var bar: MiniPlayerBar?
    private var fallbackContainer: UIView?

    private static let fallbackHeight: CGFloat = 56
    private static let fallbackGap: CGFloat = 8

    init(tabBar: TabBarController) {
        self.tabBar = tabBar
    }

    /// The dock of the window `viewController` is in, when that window shows the main app.
    static func of(_ viewController: UIViewController) -> MiniPlayerDock? {
        let tabBar = viewController.view.window?.rootViewController as? TabBarController
            ?? viewController.tabBarController as? TabBarController
        return tabBar?.miniPlayer
    }

    /// The player shrunk into the bar, if there is one.
    var docked: PlayerCoordinator? {
        active?.isDocked == true ? active : nil
    }

    /// Where a docked player and its alerts are presented from: the topmost screen of the window.
    var presentationHost: UIViewController {
        var host: UIViewController = tabBar
        while let next = host.presentedViewController, !next.isBeingDismissed {
            host = next
        }
        return host
    }

    var tabBarController: TabBarController { tabBar }

    /// Makes `coordinator` this window's player. One playing here before it ends, so a window plays one title at a time.
    func adopt(_ coordinator: PlayerCoordinator) {
        guard active !== coordinator else { return }
        let previous = active
        active = coordinator
        removeBar(animated: true)
        previous?.close()
    }

    /// Lets go of `coordinator` once it has ended, taking the bar away with it.
    func release(_ coordinator: PlayerCoordinator) {
        guard active === coordinator else { return }
        active = nil
        removeBar(animated: true)
    }

    /// Shows the bar for `coordinator`, live, now that its full screen has gone.
    func dock(_ coordinator: PlayerCoordinator, player: AVPlayer) {
        guard active === coordinator else { return }
        let bar = bar ?? installBar()
        bar.attach(player: player, scene: tabBar.view.window?.windowScene)
        describe(coordinator, in: bar)
        bar.isLive = true
    }

    /// Takes the bar down again for a player that did not dock after all.
    func withdraw(_ coordinator: PlayerCoordinator) {
        guard active === coordinator else { return }
        removeBar(animated: true)
    }

    /// The full player is opening over the bar, which stops drawing the picture until it comes back.
    func expanding(_ coordinator: PlayerCoordinator) {
        guard active === coordinator else { return }
        bar?.isLive = false
    }

    /// Follows the player onto the next item: its picture and its title.
    func follow(_ coordinator: PlayerCoordinator, to player: AVPlayer) {
        guard active === coordinator, let bar else { return }
        bar.attach(player: player, scene: tabBar.view.window?.windowScene)
        describe(coordinator, in: bar)
    }

    func showPosition(of coordinator: PlayerCoordinator, at seconds: Double) {
        guard active === coordinator else { return }
        bar?.showPosition(seconds)
    }

    /// Ends the window's player, for a window that is about to show something other than the main app.
    func closeActive() {
        active?.close()
    }

    private func describe(_ coordinator: PlayerCoordinator, in bar: MiniPlayerBar) {
        let metadata = coordinator.nowPlayingMetadata
        let subtitle = metadata?.showName.map { show in
            [show, Formatters.episodeCode(metadata?.seasonNumber, metadata?.episodeNumber)].compactMap { $0 }.joined(separator: " · ")
        }
        bar.configure(title: metadata?.title ?? "", subtitle: subtitle, duration: metadata?.duration ?? 0)
        if let position = coordinator.currentPosition {
            bar.showPosition(position)
        }
    }

    private func installBar() -> MiniPlayerBar {
        let bar = MiniPlayerBar()
        bar.onExpand = { [weak self] in self?.docked?.expand() }
        bar.onClose = { [weak self] in self?.active?.close() }
        self.bar = bar
        if #available(iOS 26.0, *) {
            tabBar.setBottomAccessory(UITabAccessory(contentView: bar), animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            installFallback(bar)
        }
        return bar
    }

    private func removeBar(animated: Bool) {
        guard let bar else { return }
        self.bar = nil
        bar.detach()
        let animates = animated && !UIAccessibility.isReduceMotionEnabled
        if #available(iOS 26.0, *) {
            tabBar.setBottomAccessory(nil, animated: animates)
        } else {
            removeFallback(animated: animates)
        }
    }

    // MARK: - Before iOS 26

    /// Before iOS 26 the tab bar has no accessory, so the bar floats in a rounded material of its own just above it.
    private func installFallback(_ bar: MiniPlayerBar) {
        let container = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        container.layer.cornerRadius = 14
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = 1 / max(tabBar.traitCollection.displayScale, 1)
        container.layer.borderColor = UIColor.separator.cgColor
        container.clipsToBounds = true
        bar.frame = container.contentView.bounds
        bar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.contentView.addSubview(bar)
        tabBar.view.insertSubview(container, belowSubview: tabBar.tabBar)
        fallbackContainer = container
        layoutFallback()
        container.alpha = 0
        container.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            container.alpha = 1
            container.transform = .identity
        }
    }

    private func removeFallback(animated: Bool) {
        guard let container = fallbackContainer else { return }
        fallbackContainer = nil
        applyFallbackInset(0)
        UIView.animate(withDuration: animated ? 0.25 : 0) {
            container.alpha = 0
            container.transform = CGAffineTransform(translationX: 0, y: 12)
        } completion: { _ in
            container.removeFromSuperview()
        }
    }

    /// Places the floating bar above a bottom tab bar, or above the home indicator where the tab bar sits on top or is hidden,
    /// and keeps every tab's content clear of it.
    func layoutFallback() {
        guard let container = fallbackContainer, let view = tabBar.view else { return }
        let bar = tabBar.tabBar
        let tabBarAtBottom = !bar.isHidden && bar.alpha > 0 && bar.frame.minY > view.bounds.midY
        let bottom = tabBarAtBottom ? bar.frame.minY : view.bounds.height - view.safeAreaInsets.bottom
        let side = max(view.safeAreaInsets.left, view.safeAreaInsets.right) + Self.fallbackGap
        let width = min(view.bounds.width - side * 2, 600)
        container.frame = CGRect(
            x: (view.bounds.width - width) / 2,
            y: bottom - Self.fallbackGap - Self.fallbackHeight,
            width: width,
            height: Self.fallbackHeight
        )
        applyFallbackInset(Self.fallbackHeight + Self.fallbackGap * 2)
    }

    private func applyFallbackInset(_ inset: CGFloat) {
        for child in tabBar.children where child.additionalSafeAreaInsets.bottom != inset {
            child.additionalSafeAreaInsets.bottom = inset
        }
    }
}
