import AVKit
import CrucibleCore
import CrucibleDesign
import UIKit

/// The Up Next card the system player presents over the video when the credits begin (or when the
/// item ends, if it has no credits marker): the next episode's frame, number and title with Play
/// Now and a second button. During credits that button is Watch Credits, which defers the proposal
/// so the credits keep playing, and Menu does the same; without credits it is Close, which rejects
/// the proposal and ends the player. With autoplay on and VoiceOver off the card counts down and
/// plays on its own, unless a run of episodes has played with nobody at the remote: then it asks
/// "Still watching?" and waits for an answer. It always renders dark, like the rest of a video
/// overlay, so its white text stays legible over the picture in either system appearance.
@MainActor
final class TVUpNextViewController: AVContentProposalViewController {
    var onDeferred: (() -> Void)?
    var isAtEndOfItem: (() -> Bool)?
    var asksStillWatching: (() -> Bool)?

    /// Whether the viewer pressed the main button, as opposed to the countdown accepting on its own.
    private(set) var acceptedByViewer = false

    private let episode: PlexMetadata
    private let autoplays: Bool
    private let hasCredits: Bool
    private let countdownLabel = UILabel()
    private let eyebrow = UILabel()
    private var stillWatching = false
    private let thumb = UIImageView()
    private var countdownTask: Task<Void, Never>?
    private var remaining = UpNextOffer.countdownSeconds
    private var playButton: UIButton?
    private var leaveButton: UIButton?

    init(offer: UpNextOffer, hasCredits: Bool) {
        episode = offer.episode
        autoplays = offer.autoplays
        self.hasCredits = hasCredits
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Counts down only when autoplay is on, VoiceOver is off and nobody needs asking: a countdown the
    /// viewer cannot see must not start the next episode under them, and neither may one nobody is awake for.
    private var isCounting: Bool { autoplays && !stillWatching && !UIAccessibility.isVoiceOverRunning }

    private var animatesDismissal: Bool { !UIAccessibility.isReduceMotionEnabled }

    func setPreview(_ image: UIImage) {
        thumb.image = image
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.upNext"
        buildCard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        stillWatching = asksStillWatching?() ?? false
        eyebrow.text = UpNextText.eyebrow(asksStillWatching: stillWatching)
        playButton?.configuration?.title = UpNextText.playTitle(asksStillWatching: stillWatching)
        playButton?.accessibilityLabel = UpNextText.playTitle(asksStillWatching: stillWatching)
        refreshLeaveButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        announce()
        startCountdown()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTask?.cancel()
        countdownTask = nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else {
            super.pressesBegan(presses, with: event)
            return
        }
        leaveCard()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        playButton.map { [$0] } ?? super.preferredFocusEnvironments
    }

    private var code: String? { Formatters.episodeCode(episode.parentIndex, episode.index) }

    /// Whether leaving the card lets the credits play on: only while they are still playing. Deferring
    /// a card that appears at the end of the item would replay it, so there leaving closes the player.
    private var leavingKeepsPlaying: Bool {
        hasCredits && !(isAtEndOfItem?() ?? false)
    }

    private func refreshLeaveButton() {
        let keeps = leavingKeepsPlaying
        leaveButton?.configuration?.title = UpNextText.leaveTitle(keepsCreditsPlaying: keeps)
        leaveButton?.accessibilityLabel = UpNextText.leaveTitle(keepsCreditsPlaying: keeps)
        leaveButton?.accessibilityHint = UpNextText.leaveHint(keepsCreditsPlaying: keeps)
    }

    /// Defers during credits so they keep playing, rejects (ending the player) when there are none.
    private func leaveCard() {
        if leavingKeepsPlaying {
            onDeferred?()
            dismissContentProposal(for: .defer, animated: animatesDismissal, completion: nil)
        } else {
            dismissContentProposal(for: .reject, animated: animatesDismissal, completion: nil)
        }
    }

    private func announce() {
        let seconds = isCounting ? UpNextOffer.countdownSeconds : nil
        let text = stillWatching
            ? UpNextText.stillWatchingAnnouncement(code: code, title: episode.title)
            : UpNextText.announcement(code: code, title: episode.title, seconds: seconds)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func buildCard() {
        let glass = Glass.effectView(fallback: .dark)
        glass.clipsToBounds = true
        glass.layer.cornerRadius = Theme.Radius.l
        glass.layer.cornerCurve = .continuous
        glass.translatesAutoresizingMaskIntoConstraints = false

        eyebrow.text = UpNextText.eyebrow(asksStillWatching: stillWatching)
        eyebrow.font = Theme.Font.caption1
        eyebrow.textColor = Theme.Color.accentText

        let title = UILabel()
        title.text = episode.title
        title.font = Theme.Font.title3
        title.textColor = Theme.Color.onArt
        title.numberOfLines = 2

        countdownLabel.font = Theme.Font.callout
        countdownLabel.textColor = Theme.Color.onArtSecondary
        countdownLabel.accessibilityTraits = .updatesFrequently
        updateSecondaryText()

        let leave = TVButton.make(.glass, title: "Close") { [weak self] in
            self?.leaveCard()
        }
        leaveButton = leave
        refreshLeaveButton()
        let play = TVButton.make(.primary, title: UpNextText.playTitle(asksStillWatching: stillWatching), symbol: "play.fill") { [weak self] in
            guard let self else { return }
            acceptedByViewer = true
            dismissContentProposal(for: .accept, animated: animatesDismissal, completion: nil)
        }
        play.accessibilityIdentifier = "player.upNext.play"
        leave.accessibilityIdentifier = "player.upNext.leave"
        playButton = play
        let buttons = UIStackView(arrangedSubviews: [leave, play])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Space.m

        let texts = UIStackView(arrangedSubviews: [eyebrow, title, countdownLabel, buttons])
        texts.axis = .vertical
        texts.alignment = .leading
        texts.spacing = Theme.Space.xs
        texts.setCustomSpacing(Theme.Space.m, after: countdownLabel)

        let row = UIStackView(arrangedSubviews: [makeThumb(), texts])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.l
        row.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(glass)
        glass.contentView.addSubview(row)
        let inset = Theme.Space.l
        NSLayoutConstraint.activate([
            glass.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: inset),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -inset),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -inset),
        ])
    }

    private func makeThumb() -> UIView {
        thumb.contentMode = .scaleAspectFill
        thumb.backgroundColor = Theme.Color.surfaceHigh
        thumb.layer.cornerRadius = Theme.Radius.m
        thumb.layer.cornerCurve = .continuous
        thumb.layer.masksToBounds = true
        thumb.isAccessibilityElement = false
        thumb.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 320),
            thumb.heightAnchor.constraint(equalToConstant: 180),
        ])
        return thumb
    }

    private func updateSecondaryText() {
        countdownLabel.text = UpNextText.secondary(code: code, remaining: remaining, counting: isCounting)
        countdownLabel.accessibilityLabel = UpNextText.spokenSecondary(code: code, remaining: remaining, counting: isCounting)
    }

    private func startCountdown() {
        updateSecondaryText()
        guard isCounting, countdownTask == nil else { return }
        remaining = UpNextOffer.countdownSeconds
        countdownTask = Task { [weak self] in
            while let self, self.remaining > 0 {
                self.updateSecondaryText()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self.remaining -= 1
            }
            guard let self else { return }
            dismissContentProposal(for: .accept, animated: animatesDismissal, completion: nil)
        }
    }
}
