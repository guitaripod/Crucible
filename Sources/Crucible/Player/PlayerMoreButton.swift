import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// A small glass button on the right edge of the player that opens Crucible's own player menu (subtitles, audio, the sleep
/// timer, chapters), because the system player has no place for one on the iPhone. It shows with a tap on the video, like the system's controls, and
/// fades a few seconds later; with VoiceOver on it stays.
@MainActor
final class PlayerMoreButton: NSObject, UIGestureRecognizerDelegate {
    private static let size: CGFloat = 44
    private static let visibleFor: Duration = .seconds(4)

    private let glass = Glass.effectView(fallback: .systemThinMaterialDark, interactive: true)
    private let button = UIButton(configuration: .plain())
    private var hideTask: Task<Void, Never>?
    private var tap: UITapGestureRecognizer?
    private let makeMenu: @MainActor () -> UIMenu

    init(makeMenu: @escaping @MainActor () -> UIMenu) {
        self.makeMenu = makeMenu
        super.init()
    }

    func install(in host: UIView, listeningOn playerView: UIView) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        if #available(iOS 26.0, *) {
            glass.cornerConfiguration = .capsule()
        } else {
            glass.layer.cornerRadius = Self.size / 2
        }
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.menu = makeMenu()
        button.accessibilityLabel = String(localized: "More", comment: "Accessibility label of the player's own menu button")
        button.accessibilityIdentifier = "player.more"
        button.isPointerInteractionEnabled = true
        button.addAction(UIAction { [weak self] _ in self?.keepVisible() }, for: .menuActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(button)
        host.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: Self.size),
            glass.heightAnchor.constraint(equalToConstant: Self.size),
            glass.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            glass.centerYAnchor.constraint(equalTo: host.safeAreaLayoutGuide.centerYAnchor),
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        let recognizer = UITapGestureRecognizer(target: nil, action: nil)
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(videoTapped))
        playerView.addGestureRecognizer(recognizer)
        tap = recognizer
        setVisible(UIAccessibility.isVoiceOverRunning, animated: false)
    }

    /// Rebuilds the menu, so it shows the sleep timer as it stands now.
    func refreshMenu() {
        button.menu = makeMenu()
    }

    func remove() {
        hideTask?.cancel()
        if let tap { tap.view?.removeGestureRecognizer(tap) }
        glass.removeFromSuperview()
    }

    /// The tap recognizer must not take taps from the system's own controls; it only listens.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func videoTapped() {
        refreshMenu()
        let showing = glass.alpha > 0.5
        setVisible(!showing || UIAccessibility.isVoiceOverRunning, animated: true)
        if !showing { scheduleHide() }
    }

    private func keepVisible() {
        hideTask?.cancel()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            self?.setVisible(false, animated: true)
        }
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        let apply = { [glass] in glass.alpha = visible ? 1 : 0 }
        glass.isUserInteractionEnabled = visible
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }
}

/// A menu of audio or subtitle tracks; image-based subtitles are listed but cannot be picked.
@MainActor
enum PlayerTrackMenu {
    static func menu(title: String, symbol: String, options: [TrackOption], select: @escaping @MainActor (Int?) -> Void) -> UIMenu {
        let actions = options.map { option in
            let action = UIAction(title: option.title, subtitle: option.detail, state: option.isSelected ? .on : .off) { _ in select(option.id) }
            if !option.isEnabled { action.attributes.insert(.disabled) }
            return action
        }
        return UIMenu(title: title, image: UIImage(systemName: symbol), children: actions)
    }
}

/// The player menu's sleep timer section, shared with the keyboard command.
@MainActor
enum PlayerSleepMenu {
    static func menu(timer: SleepTimer?, isEpisode: Bool, set: @escaping @MainActor (SleepTimerChoice?) -> Void) -> UIMenu {
        let off = UIAction(title: SleepTimer.off, state: timer == nil ? .on : .off) { _ in set(nil) }
        let choices = SleepTimerChoice.all.map { choice in
            UIAction(title: choice.title(isEpisode: isEpisode), state: timer?.choice == choice ? .on : .off) { _ in
                Haptics.selection()
                set(choice)
            }
        }
        let title = timer?.menuTitle(isEpisode: isEpisode) ?? SleepTimer.title
        return UIMenu(title: title, image: UIImage(systemName: timer == nil ? "moon.zzz" : "moon.zzz.fill"), children: [off] + choices)
    }
}
