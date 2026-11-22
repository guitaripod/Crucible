import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Live TV › Playlists: the channel playlists the viewer added, each opening its own page, Add Playlist, Plex's free
/// channels on or off, and Refresh Channels. Adding asks for the address, reads the playlist to check it and names it
/// after its host; the guide address comes from the playlist itself unless the viewer gives one.
@MainActor
final class LivePlaylistsScreen: SettingsScaffold {
    private enum RowID {
        static let destination = "livetv.destination"
        static let add = "livetv.add"
        static let plex = "livetv.plex"
        static let refresh = "livetv.refresh"
        static let playlistPrefix = "livetv.playlist."
    }

    private let panel = ContextPanel(content: .init(symbol: "antenna.radiowaves.left.and.right", title: LiveTVCopy.playlists, body: LiveTVCopy.playlistNote))
    private var isChecking = false
    private let showsDestinationToggle: Bool

    init(title: String = LiveTVCopy.playlists, showsDestinationToggle: Bool = false) {
        self.showsDestinationToggle = showsDestinationToggle
        super.init(title: title)
        installContext(panel)
        render()
    }

    override func screenDidAppear() {
        render()
    }

    private func render() {
        var items: [RowItem] = []
        if showsDestinationToggle {
            items.append(RowItem.onOff(id: RowID.destination, title: LiveTVCopy.showDestination, subtitle: WebSettingsCopy.showDestinationHint,
                                       isOn: LiveTVPreferences.showsDestination, symbol: "antenna.radiowaves.left.and.right"))
        }
        items += LivePlaylistStore.all().map { playlist in
            RowItem(id: RowID.playlistPrefix + playlist.id, title: playlist.name, subtitle: playlist.address.host, symbol: "list.bullet", accessory: .chevron)
        }
        items.append(RowItem(id: RowID.add, title: isChecking ? LiveTVCopy.checkingPlaylist : LiveTVCopy.addPlaylist, symbol: "plus", isEnabled: !isChecking))
        items.append(RowItem.onOff(id: RowID.plex, title: LiveTVCopy.showPlexChannels, subtitle: LiveTVCopy.showPlexChannelsFooter,
                                   isOn: LiveTVPreferences.showsPlexChannels, symbol: "tv"))
        items.append(RowItem(id: RowID.refresh, title: LiveTVCopy.refreshPlaylists, symbol: "arrow.clockwise"))
        setRows(items)
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.destination:
            LiveTVPreferences.showsDestination.toggle()
            render()
        case RowID.add: presentAdd()
        case RowID.plex:
            LiveTVPreferences.showsPlexChannels.toggle()
            render()
        case RowID.refresh:
            LiveTVPreferences.reset()
            NotificationCenter.default.post(name: .liveSourcesChanged, object: nil)
            if let window { AlertView.notice(title: LiveTVCopy.refreshPlaylists, message: nil, in: window) }
        default:
            guard id.hasPrefix(RowID.playlistPrefix) else { return }
            let playlistID = String(id.dropFirst(RowID.playlistPrefix.count))
            rootView?.push(LivePlaylistScreen(playlistID: playlistID))
        }
    }

    /// Asks for a playlist's address, then reads it to check it before adding it.
    func presentAdd() {
        guard let window else {
            Task { @MainActor [weak self] in self?.presentAdd() }
            return
        }
        let offered = window.pasteboardText().flatMap(LivePlaylist.address(from:))?.absoluteString ?? ""
        weak var alert: AlertView?
        let shown = AlertView(title: LiveTVCopy.addPlaylist, message: LiveTVCopy.playlistNote, actions: [
            AlertView.Action(LiveTVCopy.add) { [weak self] in
                guard let address = LivePlaylist.address(from: alert?.text ?? "") else {
                    AlertView.notice(title: LiveTVCopy.invalidAddress, message: nil, in: window)
                    return
                }
                self?.add(LivePlaylist(name: LivePlaylist.suggestedName(for: address), address: address))
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: LiveTVCopy.playlistAddress, fieldText: offered)
        alert = shown
        shown.present(in: window)
    }

    /// Adds `playlist` once it reads as a channel playlist, saying how many channels it has.
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
                self.render()
                if let window = self.window { AlertView.notice(title: LiveTVCopy.playlistAdded(playlist.name, channels: count), message: nil, in: window) }
            case .failure(let message):
                self.render()
                if let window = self.window { AlertView.notice(title: LiveTVCopy.failedTitle, message: message, in: window) }
            }
        }
    }
}

/// One playlist's page: its name, addresses and user agent, each changed in place, and Remove.
@MainActor
final class LivePlaylistScreen: SettingsScaffold {
    private enum RowID {
        static let name = "name"
        static let address = "address"
        static let guide = "guide"
        static let agent = "agent"
        static let remove = "remove"
    }

    private let playlistID: String

    init(playlistID: String) {
        self.playlistID = playlistID
        super.init(title: LiveTVCopy.editPlaylist)
        render()
    }

    private var playlist: LivePlaylist? { LivePlaylistStore.all().first { $0.id == playlistID } }

    private func render() {
        guard let playlist else {
            setRows([])
            return
        }
        heading.title = playlist.name
        setRows([
            RowItem(id: RowID.name, title: LiveTVCopy.playlistName, value: playlist.name, symbol: "pencil", accessory: .chevron),
            RowItem(id: RowID.address, title: LiveTVCopy.playlistAddress, value: playlist.address.host, symbol: "link", accessory: .chevron),
            RowItem(id: RowID.guide, title: LiveTVCopy.guideAddress, value: playlist.guideAddress?.host ?? "", symbol: "calendar", accessory: .chevron),
            RowItem(id: RowID.agent, title: LiveTVCopy.userAgent, value: playlist.userAgent ?? "", symbol: "person", accessory: .chevron),
            RowItem(id: RowID.remove, title: LiveTVCopy.removePlaylist, symbol: "trash", isDestructive: true),
        ])
    }

    override func rowSelected(_ id: String) {
        guard let window, var playlist else { return }
        switch id {
        case RowID.name:
            ask(LiveTVCopy.playlistName, text: playlist.name) { text in
                guard !text.isEmpty else { return }
                playlist.name = text
                LivePlaylistStore.save(playlist)
            }
        case RowID.address:
            ask(LiveTVCopy.playlistAddress, text: playlist.address.absoluteString) { text in
                guard let url = LivePlaylist.address(from: text) else {
                    AlertView.notice(title: LiveTVCopy.invalidAddress, message: nil, in: window)
                    return
                }
                playlist.address = url
                LivePlaylistStore.save(playlist)
            }
        case RowID.guide:
            ask(LiveTVCopy.guideAddress, text: playlist.guideAddress?.absoluteString ?? "") { text in
                playlist.guideAddress = text.isEmpty ? nil : LivePlaylist.address(from: text)
                LivePlaylistStore.save(playlist)
            }
        case RowID.agent:
            ask(LiveTVCopy.userAgent, text: playlist.userAgent ?? "") { text in
                playlist.userAgent = text.isEmpty ? nil : text
                LivePlaylistStore.save(playlist)
            }
        case RowID.remove:
            AlertView(title: LiveTVCopy.removePlaylistQuestion, message: LiveTVCopy.removePlaylistText, actions: [
                AlertView.Action(LiveTVCopy.removePlaylist, role: .destructive) { [weak self] in
                    LivePlaylistStore.remove(id: playlist.id)
                    self?.navigation?.pop()
                },
                AlertView.Action(String(localized: "Cancel"), role: .cancel),
            ]).present(in: window)
        default:
            break
        }
    }

    private func ask(_ title: String, text: String, then apply: @escaping (String) -> Void) {
        guard let window else { return }
        weak var alert: AlertView?
        let shown = AlertView(title: title, actions: [
            AlertView.Action(String(localized: "Save")) { [weak self] in
                apply((alert?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                self?.render()
            },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: title, fieldText: text)
        alert = shown
        shown.present(in: window)
    }
}
