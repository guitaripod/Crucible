import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// What the Beta tag beside Live TV opens on the Apple TV: a centred panel over the dimmed guide saying what Live TV does
/// today, with Got It. Menu closes it.
final class TVLiveBetaNoteViewController: UIViewController {
    private let dismissButton = UIButton(type: .system)

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        let panel = UIView()
        panel.backgroundColor = Theme.Color.surface
        panel.layer.cornerRadius = Theme.Radius.l
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        let tag = BetaTag.button(title: LiveTVCopy.beta, action: UIAction { _ in })
        tag.isUserInteractionEnabled = false
        stack.addArrangedSubview(UIStackView(arrangedSubviews: [tag, UIView()]))
        stack.addArrangedSubview(label(LiveTVCopy.betaTitle, font: Theme.Font.title2, color: Theme.Color.label))
        stack.addArrangedSubview(label(LiveTVCopy.betaIntro, font: TVFont.screenDetail, color: Theme.Color.labelSecondary))
        for point in LiveTVCopy.betaPoints {
            let image = UIImageView(image: UIImage(systemName: point.symbol))
            image.tintColor = Theme.Color.accent
            image.contentMode = .center
            image.backgroundColor = Theme.Color.accentTint
            image.layer.cornerRadius = Theme.Radius.xs
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: TVFont.cardTitle)
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 64), image.heightAnchor.constraint(equalToConstant: 64)])
            let row = UIStackView(arrangedSubviews: [image, label(point.text, font: TVFont.cardTitle, color: Theme.Color.label)])
            row.spacing = Theme.Space.m
            row.alignment = .center
            stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(label(LiveTVCopy.betaFooter, font: TVFont.cardSubtitle, color: Theme.Color.labelSecondary))
        var configuration = UIButton.Configuration.filled()
        configuration.title = LiveTVCopy.betaDismiss
        dismissButton.configuration = configuration
        dismissButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: TVMotion.animationsEnabled) }, for: .primaryActionTriggered)
        dismissButton.accessibilityIdentifier = "livetv.beta.dismiss"
        stack.addArrangedSubview(dismissButton)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 1100),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: Theme.Space.xl),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -Theme.Space.xl),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Theme.Space.xl),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -Theme.Space.xl),
        ])
        view.accessibilityIdentifier = "livetv.beta.note"
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [dismissButton] }

    private func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
}

/// Live TV's settings and the viewer's channel playlists on the Apple TV: Show Live TV (from Settings), Plex's free
/// channels, each playlist (Select to edit or remove it), Add Playlist, typed with the on-screen keyboard or an iPhone's,
/// and Refresh Channels.
final class TVLivePlaylistsViewController: TVSettingsScaffold {
    private let showsDestinationSwitch: Bool
    private let heading = TVSettingsHeading(title: LiveTVCopy.playlists, body: LiveTVCopy.playlistNote)
    private var isChecking = false
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    init(showsDestinationSwitch: Bool) {
        self.showsDestinationSwitch = showsDestinationSwitch
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if showsDestinationSwitch { heading.setTitle(LiveTVCopy.title) }
        installHeading(heading)
        collectionView.accessibilityIdentifier = "livetv.playlists"
        render()
        observer = NotificationCenter.default.addObserver(forName: .liveSourcesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    private func render() {
        var rows: [TVRowItem] = []
        if showsDestinationSwitch {
            rows.append(TVRowItem(id: "destination", title: LiveTVCopy.showDestination, value: LiveTVPreferences.showsDestination ? String(localized: "On") : String(localized: "Off"),
                                  symbol: "antenna.radiowaves.left.and.right"))
        }
        rows.append(TVRowItem(id: "plex", title: LiveTVCopy.showPlexChannels, subtitle: LiveTVCopy.showPlexChannelsFooter,
                              value: LiveTVPreferences.showsPlexChannels ? String(localized: "On") : String(localized: "Off"), symbol: "tv"))
        rows.append(TVRowItem(id: "merge", title: LiveTVCopy.mergeDuplicates, subtitle: LiveTVCopy.mergeDuplicatesFooter,
                              value: LiveTVPreferences.mergesDuplicates ? String(localized: "On") : String(localized: "Off"), symbol: "square.on.square"))
        for playlist in LivePlaylistStore.all() {
            rows.append(TVRowItem(id: "playlist.\(playlist.id)", title: playlist.name, subtitle: playlist.address.host, symbol: "list.bullet", accessory: .chevron))
        }
        rows.append(TVRowItem(id: "add", title: isChecking ? LiveTVCopy.checkingPlaylist : LiveTVCopy.addPlaylist, symbol: "plus", isEnabled: !isChecking))
        rows.append(TVRowItem(id: "refresh", title: LiveTVCopy.refreshPlaylists, symbol: "arrow.clockwise"))
        setRows(rows)
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case "destination":
            LiveTVPreferences.showsDestination.toggle()
            render()
        case "plex":
            LiveTVPreferences.showsPlexChannels.toggle()
            render()
        case "merge":
            LiveTVPreferences.mergesDuplicates.toggle()
            render()
        case "add":
            presentAdd()
        case "refresh":
            LiveTVPreferences.reset()
            NotificationCenter.default.post(name: .liveSourcesChanged, object: nil)
        default:
            guard id.hasPrefix("playlist."), let playlist = LivePlaylistStore.all().first(where: { "playlist.\($0.id)" == id }) else { return }
            presentEdit(playlist)
        }
    }

    private func presentAdd() {
        presentTextEntry(title: LiveTVCopy.addPlaylist, message: LiveTVCopy.playlistNote, text: "", placeholder: LiveTVCopy.playlistAddress, keyboard: .URL,
                         confirmTitle: LiveTVCopy.add) { [weak self] text in
            guard let self else { return }
            guard let address = LivePlaylist.address(from: text) else {
                self.presentAlert(title: LiveTVCopy.invalidAddress)
                return
            }
            self.add(LivePlaylist(name: LivePlaylist.suggestedName(for: address), address: address))
        }
    }

    func add(_ playlist: LivePlaylist) {
        isChecking = true
        render()
        Task { [weak self] in
            let result = await LivePlaylistCheck.check(playlist)
            guard let self else { return }
            self.isChecking = false
            switch result {
            case .success(let count):
                LivePlaylistStore.save(playlist)
                self.presentAlert(title: LiveTVCopy.playlistAdded(playlist.name, channels: count))
            case .failure(let message):
                self.presentAlert(title: LiveTVCopy.failedTitle, message: message)
            }
            self.render()
        }
    }

    private func presentEdit(_ playlist: LivePlaylist) {
        let sheet = UIAlertController(title: playlist.name, message: playlist.address.host, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: LiveTVCopy.playlistName, style: .default) { [weak self] _ in
            self?.presentTextEntry(title: LiveTVCopy.playlistName, text: playlist.name, confirmTitle: String(localized: "Save")) { text in
                var changed = playlist
                changed.name = text.isEmpty ? playlist.name : text
                LivePlaylistStore.save(changed)
            }
        })
        sheet.addAction(UIAlertAction(title: LiveTVCopy.guideAddress, style: .default) { [weak self] _ in
            self?.presentTextEntry(title: LiveTVCopy.guideAddress, text: playlist.guideAddressesText, keyboard: .URL, confirmTitle: String(localized: "Save")) { text in
                var changed = playlist
                changed.guideAddresses = LivePlaylist.addresses(from: text)
                LivePlaylistStore.save(changed)
            }
        })
        sheet.addAction(UIAlertAction(title: LiveTVCopy.removePlaylist, style: .destructive) { [weak self] _ in
            self?.presentConfirmation(title: LiveTVCopy.removePlaylistQuestion, message: LiveTVCopy.removePlaylistText, confirmTitle: LiveTVCopy.removePlaylist) {
                LivePlaylistStore.remove(id: playlist.id)
            }
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: TVMotion.animationsEnabled)
    }
}

/// Live TV › Recordings on the Apple TV: what the server is recording and will record, and the standing rules; Select
/// cancels a recording or deletes a rule.
final class TVLiveRecordingsViewController: TVSettingsScaffold {
    private let api: APIClient
    private let heading = TVSettingsHeading(title: LiveTVCopy.recordings, body: LiveTVCopy.recordingNeedsPass)
    private var scheduled: [ScheduledRecording] = []
    private var rules: [RecordingRule] = []
    private lazy var loadSlot = makeTaskSlot()
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    init(api: APIClient) {
        self.api = api
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        observer = NotificationCenter.default.addObserver(forName: .liveRecordingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
        presentState(.loading(title: nil))
        load()
    }

    private func load() {
        let api = api
        loadSlot.run { [weak self] in
            do {
                async let scheduled = LiveRecordings.scheduled(api: api)
                async let rules = LiveRecordings.rules(api: api)
                let (found, standing) = try await (scheduled, rules)
                guard let self, !Task.isCancelled else { return }
                self.scheduled = found.filter { $0.status != .complete }
                self.rules = standing
                self.render()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.presentState(.error(title: LiveTVCopy.recordings, message: LiveTVCopy.recordingError(error), retryTitle: LiveTVCopy.tryAgain,
                                         retry: { [weak self] in self?.load() }))
            }
        }
    }

    private func render() {
        guard !scheduled.isEmpty || !rules.isEmpty else {
            presentState(.empty(title: LiveTVCopy.noRecordings, message: LiveTVCopy.noRecordingsText, symbol: "record.circle", action: nil))
            return
        }
        var rows: [TVRowItem] = scheduled.map { recording in
            let status: String = switch recording.status {
            case .recording: LiveTVCopy.recordingNow
            case .failed: LiveTVCopy.failedStatus
            default: recording.start.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            }
            return TVRowItem(id: "r.\(recording.id)", title: recording.title, subtitle: [recording.episodeTitle, recording.channel].compactMap { $0 }.joined(separator: " · "),
                             value: status, symbol: recording.status == .recording ? "record.circle.fill" : "calendar")
        }
        rows += rules.map { rule in
            TVRowItem(id: "s.\(rule.id)", title: rule.title, subtitle: [rule.airings, rule.library].compactMap { $0 }.joined(separator: " · "),
                      value: rule.isSeries ? LiveTVCopy.recordSeries : LiveTVCopy.recordEpisode, symbol: "repeat")
        }
        setRows(rows)
        presentState(nil)
    }

    override func rowDidSelect(_ id: String) {
        if let recording = scheduled.first(where: { "r.\($0.id)" == id }) {
            presentConfirmation(title: recording.title, message: recording.episodeTitle, confirmTitle: LiveTVCopy.cancelRecording) { [weak self] in
                self?.perform { try await LiveRecordings.cancel(recording, api: $0) }
            }
        } else if let rule = rules.first(where: { "s.\($0.id)" == id }) {
            presentConfirmation(title: LiveTVCopy.deleteRuleQuestion, message: LiveTVCopy.deleteRuleText, confirmTitle: LiveTVCopy.deleteRule) { [weak self] in
                self?.perform { try await LiveRecordings.deleteRule(rule.id, api: $0) }
            }
        }
    }

    private func perform(_ change: @escaping @Sendable (APIClient) async throws -> Void) {
        let api = api
        Task { [weak self] in
            do {
                try await change(api)
            } catch {
                self?.presentAlert(title: LiveTVCopy.recordingError(error))
            }
        }
    }
}
