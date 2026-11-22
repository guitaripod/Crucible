import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// Settings › Web Video: the quality and codec picked on their own, what happens at the stretches SponsorBlock marks,
/// Shorts, the subscriptions' way in and out (a file from another app, an OPML list), and the optional sign-in through a
/// browser's cookies with what it risks said plainly.
@MainActor
final class WebSettingsScreen: SettingsScaffold {
    private enum RowID {
        static let quality = "web.quality"
        static let codec = "web.codec"
        static let sponsor = "web.sponsor"
        static let shorts = "web.shorts"
        static let destination = "web.destination"
        static let importFile = "web.import"
        static let export = "web.export"
        static let clearHistory = "web.clearHistory"
        static let cookies = "web.cookies"
        static let markWatched = "web.markWatched"
        static let importAccount = "web.importAccount"
        static let tool = "web.tool"
    }

    /// The browsers yt-dlp reads cookies from, as it names them.
    private static let browsers = ["firefox", "chrome", "chromium", "brave", "vivaldi", "edge", "opera"]

    private let panel = ContextPanel(content: .init(symbol: "play.rectangle", title: WebSettingsCopy.title, body: WebSettingsCopy.explanation))
    private var toolVersion: String?
    private var isImporting = false

    init() {
        super.init(title: WebSettingsCopy.title)
        installContext(panel)
        render()
    }

    override func screenDidAppear() {
        render()
        Task { [weak self] in
            let version = await WebService.shared.toolVersion()
            guard let self else { return }
            self.toolVersion = version
            self.render()
        }
    }

    private func render() {
        let library = WebService.shared.library
        let signedIn = WebSettings.cookiesBrowser != nil
        var items = [
            RowItem(id: RowID.quality, title: WebSettingsCopy.quality, value: WebSettings.quality.title, symbol: "sparkles.tv", accessory: .chevron),
            RowItem(id: RowID.codec, title: WebSettingsCopy.codec, subtitle: WebSettingsCopy.codecHint, value: WebSettings.codecTitle(WebSettings.codec),
                    symbol: "film", accessory: .chevron),
            RowItem(id: RowID.sponsor, title: WebSettingsCopy.sponsor, subtitle: WebSettingsCopy.sponsorHint, value: WebSettings.sponsorMode.title,
                    symbol: "forward.end.fill", accessory: .chevron),
            RowItem.onOff(id: RowID.shorts, title: WebSettingsCopy.hideShorts, isOn: WebSettings.hidesShorts, symbol: "eye.slash"),
            RowItem.onOff(id: RowID.destination, title: WebSettingsCopy.showDestination, subtitle: WebSettingsCopy.showDestinationHint,
                          isOn: WebSettings.showsDestination, symbol: "play.rectangle"),
            RowItem(id: RowID.importFile, title: WebSettingsCopy.importFile, subtitle: WebSettingsCopy.importFileHint, symbol: "tray.and.arrow.down", accessory: .chevron),
        ]
        if !library.subscriptions.isEmpty {
            items.append(RowItem(id: RowID.export, title: WebSettingsCopy.export, subtitle: WebSettingsCopy.exportHint, symbol: "tray.and.arrow.up"))
        }
        items.append(RowItem(id: RowID.cookies, title: WebSettingsCopy.cookies, subtitle: WebSettingsCopy.cookiesHint,
                             value: WebSettings.cookiesBrowser.map(Self.browserName) ?? String(localized: "Off"), symbol: "key", accessory: .chevron))
        if signedIn {
            items.append(RowItem.onOff(id: RowID.markWatched, title: WebSettingsCopy.markWatched, subtitle: WebSettingsCopy.markWatchedHint,
                                       isOn: WebSettings.marksWatched, symbol: "clock.arrow.circlepath"))
            items.append(RowItem(id: RowID.importAccount, title: isImporting ? WebSettingsCopy.importing : WebSettingsCopy.importAccount, symbol: "person.2",
                                 isEnabled: !isImporting))
        }
        if !library.history.isEmpty {
            items.append(RowItem(id: RowID.clearHistory, title: WebSettingsCopy.clearHistory, symbol: "trash", isDestructive: true))
        }
        items.append(RowItem(id: RowID.tool, title: "yt-dlp", subtitle: WebSettingsCopy.toolHint,
                             value: toolVersion ?? (WebService.shared.isAvailable ? "" : WebSettingsCopy.notInstalled), symbol: "wrench.and.screwdriver"))
        setRows(items)
    }

    private static func browserName(_ browser: String) -> String {
        browser == "edge" ? "Edge" : browser.prefix(1).uppercased() + browser.dropFirst()
    }

    override func rowSelected(_ id: String) {
        guard let window else { return }
        switch id {
        case RowID.quality:
            choose(WebSettingsCopy.quality, among: WebSettings.Quality.allCases.map { ($0.rawValue, $0.title, $0 == WebSettings.quality) }) { raw in
                if let quality = WebSettings.Quality(rawValue: raw) { WebSettings.quality = quality }
            }
        case RowID.codec:
            choose(WebSettingsCopy.codec, among: WebPlaybackPreferences.Codec.allCases.map { ($0.rawValue, WebSettings.codecTitle($0), $0 == WebSettings.codec) }) { raw in
                if let codec = WebPlaybackPreferences.Codec(rawValue: raw) { WebSettings.codec = codec }
            }
        case RowID.sponsor:
            choose(WebSettingsCopy.sponsor, among: WebSettings.SponsorMode.allCases.map { ($0.rawValue, $0.title, $0 == WebSettings.sponsorMode) }) { raw in
                if let mode = WebSettings.SponsorMode(rawValue: raw) { WebSettings.sponsorMode = mode }
            }
        case RowID.shorts:
            WebSettings.hidesShorts.toggle()
            render()
        case RowID.destination:
            WebSettings.showsDestination.toggle()
            render()
        case RowID.importFile:
            askForFile()
        case RowID.export:
            export()
        case RowID.cookies:
            chooseBrowser()
        case RowID.markWatched:
            WebSettings.marksWatched.toggle()
            render()
        case RowID.importAccount:
            importFromAccount()
        case RowID.clearHistory:
            AlertView.confirm(title: WebSettingsCopy.clearHistory, message: WebSettingsCopy.clearHistoryHint, confirm: WebSettingsCopy.clearHistory, in: window) { [weak self] in
                WebService.shared.library.clearHistory()
                self?.render()
            }
        case RowID.tool:
            WebService.shared.locateTool()
            screenDidAppear()
        default:
            break
        }
    }

    /// A menu of `options` hanging from the row, with the one set now checked.
    private func choose(_ title: String, among options: [(id: String, title: String, isChosen: Bool)], then set: @escaping (String) -> Void) {
        guard let window else { return }
        let anchor = window.focusedView?.frameInWindow ?? frameInWindow
        let menu = MenuView(title: title, items: options.map { MenuView.Item(id: $0.id, title: $0.title, isChecked: $0.isChosen) }, anchor: anchor)
        menu.onSelect = { [weak self] item in
            set(item.id)
            self?.render()
        }
        menu.present(in: window)
    }

    /// Off, or a browser; choosing one says first what signing in this way risks.
    private func chooseBrowser() {
        guard let window else { return }
        let current = WebSettings.cookiesBrowser
        var options: [(id: String, title: String, isChosen: Bool)] = [("", String(localized: "Off"), current == nil)]
        options += Self.browsers.map { ($0, Self.browserName($0), $0 == current) }
        choose(WebSettingsCopy.cookies, among: options) { [weak self] raw in
            guard !raw.isEmpty else {
                WebSettings.cookiesBrowser = nil
                WebSettings.marksWatched = false
                return
            }
            AlertView.confirm(title: WebSettingsCopy.cookiesWarningTitle, message: WebSettingsCopy.cookiesWarning, confirm: WebSettingsCopy.cookiesConfirm,
                              role: .normal, in: window) {
                WebSettings.cookiesBrowser = raw
                self?.render()
            }
        }
    }

    private func askForFile() {
        guard let window else { return }
        weak var alert: AlertView?
        let shown = AlertView(title: WebSettingsCopy.importFile, message: WebSettingsCopy.importFileAsk, actions: [
            AlertView.Action(WebSettingsCopy.importAction) { [weak self] in self?.importFile(at: alert?.text ?? "") },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: "~/Downloads/subscriptions.csv", fieldText: Self.likelyFile() ?? "")
        alert = shown
        shown.present(in: window)
    }

    /// The subscriptions file Google Takeout leaves in its folder, or one in Downloads under a name the usual exports use.
    private static func likelyFile() -> String? {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if FileManager.default.fileExists(atPath: downloads.appendingPathComponent(WebSettingsCopy.takeoutSubscriptions).path) {
            return "~/Downloads/" + WebSettingsCopy.takeoutSubscriptions
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
        let found = names.first { name in
            let lowered = name.lowercased()
            return lowered == "subscriptions.csv" || lowered.hasSuffix(".opml") || (lowered.contains("subscriptions") && lowered.hasSuffix(".json"))
        }
        return found.map { "~/Downloads/\($0)" }
    }

    private func importFile(at typed: String) {
        guard let window else { return }
        var path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        if path.hasPrefix("~") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst() }
        guard let data = FileManager.default.contents(atPath: path) else {
            AlertView.notice(title: WebSettingsCopy.importFailed, message: WebSettingsCopy.noSuchFile, in: window)
            return
        }
        let channels = WebSubscriptionImport.channels(in: data)
        guard !channels.isEmpty else {
            AlertView.notice(title: WebSettingsCopy.importFailed, message: WebSettingsCopy.noChannelsInFile, in: window)
            return
        }
        finishImport(channels)
    }

    /// Follows the imported channels and says how many were new.
    private func finishImport(_ channels: [WebChannel]) {
        let added = WebService.shared.library.subscribe(toAll: channels)
        render()
        guard let window else { return }
        let message = added == 1 ? String(localized: "You now follow 1 more channel.", comment: "After importing subscriptions")
                                 : String(localized: "You now follow \(added) more channels.", comment: "After importing subscriptions")
        AlertView.notice(title: WebSettingsCopy.imported, message: added == 0 ? WebSettingsCopy.nothingNew : message, in: window)
    }

    /// Reads the channels the signed-in account follows from the site's own list of them.
    private func importFromAccount() {
        guard !isImporting else { return }
        isImporting = true
        render()
        Task { [weak self] in
            let outcome: Result<[WebChannel], any Error>
            do {
                let listing = try await WebService.shared.listing("https://www.youtube.com/feed/channels", limit: 2000, fresh: true)
                outcome = .success(listing.entries.compactMap { entry in
                    WebSubscriptionImport.channelID(in: entry.url).map { WebChannel(id: $0, title: entry.title, url: entry.url) }
                        ?? (entry.id.hasPrefix("UC") && entry.id.count == 24 ? WebChannel(id: entry.id, title: entry.title, url: entry.url) : nil)
                })
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.isImporting = false
            self.render()
            switch outcome {
            case .success(let channels) where !channels.isEmpty:
                self.finishImport(channels)
            case .success:
                if let window = self.window { AlertView.notice(title: WebSettingsCopy.importFailed, message: WebSettingsCopy.noChannelsInAccount, in: window) }
            case .failure(let error):
                if let window = self.window { AlertView.notice(title: WebSettingsCopy.importFailed, message: WebService.message(for: error), in: window) }
            }
        }
    }

    /// Writes the followed channels as OPML into Documents, never over a file that is there.
    private func export() {
        guard let window else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        var file = folder.appendingPathComponent("Crucible Subscriptions.opml")
        var number = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("Crucible Subscriptions \(number).opml")
            number += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try WebSubscriptionImport.opml(WebService.shared.library.subscriptions).write(to: file, options: .atomic)
            AlertView.notice(title: WebSettingsCopy.exported, message: file.path, in: window)
        } catch {
            AlertView.notice(title: WebSettingsCopy.exportFailed, message: error.localizedDescription, in: window)
        }
    }
}

/// The words of Settings › Web Video.
enum WebSettingsCopy {
    static let title = String(localized: "Web Video", comment: "Settings category: video from the web through yt-dlp")
    static let pitch = String(localized: "YouTube and other sites, through yt-dlp", comment: "Settings: one line about the Web Video category")
    static let explanation = String(localized: "Crucible plays video from YouTube and well over a thousand other sites through yt-dlp, an open-source tool on this computer. No account is needed: the channels you follow, what you saved and where you stopped are kept here and nowhere else. Skips come from SponsorBlock, whose volunteers mark sponsor reads and intros.",
                                    comment: "Settings › Web Video: what the feature is and where its data lives")
    static let quality = String(localized: "Quality", comment: "Player menu: a web video's picture quality")
    static let codec = String(localized: "Preferred Codec", comment: "Web video setting: which video codec to pick when a video has several")
    static let codecHint = String(localized: "Automatic picks AV1, then VP9, then H.264. Choose H.264 if high resolutions stutter.",
                                  comment: "Web video setting: what the codec choice does")
    static let sponsor = String(localized: "Sponsor Segments", comment: "Web video setting: what to do at stretches SponsorBlock marks")
    static let sponsorHint = String(localized: "Sponsor reads, self-promotion, reminders, intros and outros, marked by SponsorBlock’s volunteers.",
                                    comment: "Web video setting: what counts as a sponsor segment")
    static let hideShorts = String(localized: "Hide Shorts", comment: "Web video setting: leave the shelf of short vertical clips off the YouTube page")
    static let showDestination = String(localized: "Show YouTube in the Sidebar", comment: "Web video setting: whether the YouTube destination is listed")
    static let showDestinationHint = String(localized: "Takes effect the next time Crucible opens.", comment: "Web video setting: when the sidebar change applies")
    static let importFile = String(localized: "Import Subscriptions…", comment: "Web video setting: follow the channels listed in a file from another app")
    static let importFileHint = String(localized: "Google Takeout’s subscriptions.csv, an OPML list, or an export from NewPipe, FreeTube or Invidious.",
                                       comment: "Web video setting: which files Import Subscriptions reads")
    static let importFileAsk = String(localized: """
        Get the file from Google Takeout:
        1. Go to takeout.google.com and sign in.
        2. Click Deselect all, then tick YouTube and YouTube Music.
        3. Click All YouTube data included and keep only subscriptions.
        4. Create the export and download the zip when Google emails it.
        5. Unzip it, then type the path of subscriptions.csv below, such as ~/Downloads/Takeout/YouTube and YouTube Music/subscriptions/subscriptions.csv.
        """, comment: "Import Subscriptions panel: how to get the subscriptions file from Google Takeout, then where to type its path")
    /// Where Google Takeout puts a YouTube subscriptions file once the zip is unzipped into Downloads.
    static let takeoutSubscriptions = "Takeout/YouTube and YouTube Music/subscriptions/subscriptions.csv"
    static let importAction = String(localized: "Import", comment: "Button that imports subscriptions from the file named")
    static let importFailed = String(localized: "Nothing Was Imported", comment: "Alert title after an import that found nothing")
    static let noSuchFile = String(localized: "There is no file at that path.", comment: "Import Subscriptions error")
    static let noChannelsInFile = String(localized: "That file lists no YouTube channels Crucible could read.", comment: "Import Subscriptions error")
    static let noChannelsInAccount = String(localized: "The account follows no channels, or the site didn’t list them.", comment: "Import from account error")
    static let imported = String(localized: "Subscriptions Imported", comment: "Alert title after importing subscriptions")
    static let nothingNew = String(localized: "You already follow every channel in it.", comment: "After importing subscriptions that were all followed")
    static let export = String(localized: "Export Subscriptions", comment: "Web video setting: write the followed channels to an OPML file")
    static let exportHint = String(localized: "Writes an OPML list to Documents, which feed readers and other apps take in.", comment: "Web video setting: what Export does")
    static let exported = String(localized: "Subscriptions Exported", comment: "Alert title after exporting subscriptions")
    static let exportFailed = String(localized: "Couldn’t Export", comment: "Alert title when exporting subscriptions failed")
    static let cookies = String(localized: "Sign In with Browser Cookies", comment: "Web video setting: let yt-dlp use a browser's cookies")
    static let cookiesHint = String(localized: "Optional. Adds your recommendations, your account’s lists, and members-only and age-restricted videos.",
                                    comment: "Web video setting: what signing in with cookies adds")
    static let cookiesWarningTitle = String(localized: "Use This Browser’s Cookies?", comment: "Alert title before turning on cookie sign-in")
    static let cookiesWarning = String(localized: "yt-dlp will read this browser’s cookies and act as the account signed in there. Sites can restrict or close an account used outside their own apps, and yt-dlp’s authors warn of exactly that. A second account is the safer choice.",
                                       comment: "Alert message before turning on cookie sign-in: the risk in plain words")
    static let cookiesConfirm = String(localized: "Use Cookies", comment: "Button that confirms cookie sign-in")
    static let markWatched = String(localized: "Add to Account History", comment: "Web video setting: tell the site what was watched")
    static let markWatchedHint = String(localized: "Finished videos are also noted in the account’s own watch history.", comment: "Web video setting: what Add to Account History does")
    static let importAccount = String(localized: "Follow the Account’s Channels", comment: "Web video setting: import the signed-in account's subscriptions")
    static let importing = String(localized: "Reading the Account’s Channels…", comment: "Web video setting while the account's subscriptions are read")
    static let clearHistory = String(localized: "Clear History", comment: "Web video setting: forget what was watched")
    static let clearHistoryHint = String(localized: "Forgets every web video you watched and where you stopped in it. Watch Later and the channels you follow stay.",
                                         comment: "Confirmation before clearing web history")
    static let toolHint = String(localized: "The open-source tool that reads the sites. When a site stops playing, updating yt-dlp is the fix.",
                                 comment: "Web video setting: what yt-dlp is")
    static let notInstalled = String(localized: "Not Installed", comment: "Web video setting: yt-dlp is missing")
}
