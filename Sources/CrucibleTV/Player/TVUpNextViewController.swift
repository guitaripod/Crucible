import AVKit
import CrucibleCore
import CrucibleDesign
import UIKit

/// The Up Next card the system player presents over the video when the credits begin: the next
/// episode's frame, number and title with Play Now and Dismiss. With autoplay on it counts down and
/// plays on its own. Play Now accepts the proposal, Dismiss rejects it (which ends the player) and
/// Menu defers it, which keeps the credits playing. It always renders dark, like the rest of a
/// video overlay, so its white text stays legible over the picture in either system appearance.
@MainActor
final class TVUpNextViewController: AVContentProposalViewController {
    private let episode: PlexMetadata
    private let preview: UIImage?
    private let autoplays: Bool
    private let countdownLabel = UILabel()
    private var countdownTask: Task<Void, Never>?
    private var remaining = UpNextOffer.countdownSeconds
    private var playButton: UIButton?

    init(offer: UpNextOffer, preview: UIImage?) {
        episode = offer.episode
        autoplays = offer.autoplays
        self.preview = preview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.upNext"
        buildCard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        dismissContentProposal(for: .defer, animated: true, completion: nil)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        playButton.map { [$0] } ?? super.preferredFocusEnvironments
    }

    private func buildCard() {
        let glass = Glass.effectView(fallback: .dark)
        glass.clipsToBounds = true
        glass.layer.cornerRadius = Theme.Radius.l
        glass.layer.cornerCurve = .continuous
        glass.translatesAutoresizingMaskIntoConstraints = false

        let eyebrow = UILabel()
        eyebrow.text = "UP NEXT"
        eyebrow.font = Theme.Font.caption1
        eyebrow.textColor = Theme.Color.accentText

        let title = UILabel()
        title.text = episode.title
        title.font = Theme.Font.title3
        title.textColor = Theme.Color.onArt
        title.numberOfLines = 2

        countdownLabel.font = Theme.Font.callout
        countdownLabel.textColor = Theme.Color.onArtSecondary
        updateSecondaryText()

        let dismiss = TVButton.make(.glass, title: "Dismiss") { [weak self] in
            self?.dismissContentProposal(for: .reject, animated: true, completion: nil)
        }
        let play = TVButton.make(.primary, title: "Play Now", symbol: "play.fill") { [weak self] in
            self?.dismissContentProposal(for: .accept, animated: true, completion: nil)
        }
        play.accessibilityIdentifier = "player.upNext.play"
        dismiss.accessibilityIdentifier = "player.upNext.dismiss"
        playButton = play
        let buttons = UIStackView(arrangedSubviews: [dismiss, play])
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
        let thumb = UIImageView(image: preview)
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

    private func secondaryText() -> String {
        let code = Formatters.episodeCode(episode.parentIndex, episode.index)
        let status = autoplays ? "Playing in \(remaining) s" : "Next episode"
        return [code, status].compactMap { $0 }.joined(separator: " · ")
    }

    private func updateSecondaryText() {
        countdownLabel.text = secondaryText()
    }

    private func startCountdown() {
        guard autoplays, countdownTask == nil else { return }
        remaining = UpNextOffer.countdownSeconds
        countdownTask = Task { [weak self] in
            while let self, self.remaining > 0 {
                self.updateSecondaryText()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self.remaining -= 1
            }
            self?.dismissContentProposal(for: .accept, animated: true, completion: nil)
        }
    }
}
