import CrucibleCore
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The app's side of web video: yt-dlp on this machine, what it said lately, the viewer's own library, and the open
/// services beside it (SponsorBlock, the sites' caption files). Screens and the player ask here and never run yt-dlp
/// themselves.
@MainActor
final class WebService {
    static let shared = WebService()

    /// The channels followed, Watch Later and progress, in `web/library.json` beside the app's other data.
    let library: WebLibrary
    private var executable: URL?
    private var videos: [String: (video: WebVideo, at: Date)] = [:]
    private var videoTasks: [String: Task<WebVideo, any Error>] = [:]
    private var listings: [String: (listing: WebListing, at: Date)] = [:]

    /// A video's stream addresses stop working some hours after yt-dlp read them; what it said is trusted this long.
    private static let videoLife: TimeInterval = 90 * 60
    private static let listingLife: TimeInterval = 10 * 60

    private init() {
        library = WebLibrary(file: AppPlatform.persistentDirectory.appendingPathComponent("web/library.json"))
        executable = YtDlp.locate()
        MidgarLog.notice("Web video: yt-dlp \(executable == nil ? "not found" : "found")", category: .lifecycle)
    }

    /// Whether yt-dlp is installed, without which nothing from the web plays.
    var isAvailable: Bool { executable != nil }

    /// Looks for yt-dlp again, as after the viewer installed it.
    @discardableResult
    func locateTool() -> Bool {
        executable = YtDlp.locate()
        return executable != nil
    }

    private func tool() throws -> YtDlp {
        guard let executable else { throw YtDlpError.notInstalled }
        return YtDlp(executable: executable, cookiesBrowser: WebSettings.cookiesBrowser)
    }

    /// The version of the yt-dlp in use, for Diagnostics and Settings.
    func toolVersion() async -> String? {
        guard let tool = try? tool() else { return nil }
        return try? await tool.version()
    }

    /// Everything about the video at `address`. Two askers of one video share one run, and an answer is kept while its
    /// stream addresses last; `fresh` asks again regardless, as after those addresses failed.
    func video(_ address: String, fresh: Bool = false) async throws -> WebVideo {
        if !fresh, let kept = videos[address], Date().timeIntervalSince(kept.at) < Self.videoLife { return kept.video }
        if let running = videoTasks[address] { return try await running.value }
        let tool = try tool()
        let task = Task { try await tool.video(address) }
        videoTasks[address] = task
        defer { videoTasks[address] = nil }
        let video = try await task.value
        videos[address] = (video, Date())
        if videos.count > 60, let oldest = videos.min(by: { $0.value.at < $1.value.at })?.key { videos[oldest] = nil }
        return video
    }

    /// A video with the top of its comments, which takes yt-dlp noticeably longer than the video alone.
    func videoWithComments(_ address: String, limit: Int = 40) async throws -> WebVideo {
        try await tool().video(address, comments: limit)
    }

    /// A channel's tab, a playlist, a search or one of the signed-in viewer's own feeds.
    func listing(_ address: String, limit: Int = 60, fresh: Bool = false) async throws -> WebListing {
        let key = "\(address)#\(limit)"
        if !fresh, let kept = listings[key], Date().timeIntervalSince(kept.at) < Self.listingLife { return kept.listing }
        let listing = try await tool().listing(address, limit: limit)
        listings[key] = (listing, Date())
        if listings.count > 80, let oldest = listings.min(by: { $0.value.at < $1.value.at })?.key { listings[oldest] = nil }
        return listing
    }

    /// Notes the video in the signed-in account's own history on its site, when the viewer asked for that.
    func markWatched(_ address: String) {
        guard WebSettings.marksWatched, WebSettings.cookiesBrowser != nil, let tool = try? tool() else { return }
        Task.detached(priority: .utility) {
            do {
                try await tool.markWatched(address)
            } catch {
                MidgarLog.notice("Marking a web video watched failed: \(error)", category: .playback)
            }
        }
    }

    // MARK: The subscriptions feed

    private var feed: (entries: [WebEntry], at: Date, channels: Set<String>)?
    private var feedTask: Task<(entries: [WebEntry], names: [String: String]), Never>?
    private static let feedLife: TimeInterval = 15 * 60
    private static var feedFile: URL { AppPlatform.cachesDirectory.appendingPathComponent("web/feed.json") }

    /// The feed as it was last read, at once: this launch's, else the one kept from the launch before.
    var subscriptionsFeedAtHand: [WebEntry] {
        if let feed { return visible(feed.entries) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.feedFile), let kept = try? decoder.decode([WebEntry].self, from: data) else { return [] }
        let followed = Set(library.subscriptions.map(\.id))
        return visible(kept.filter { $0.channelID.map(followed.contains) ?? false })
    }

    /// The newest videos of every followed channel, newest first, read from each channel's public feed: a hundred
    /// channels are a hundred small requests, eight at a time, and none of them is a yt-dlp run. A feed read in the last
    /// quarter of an hour for the same channels is kept unless `fresh`.
    func subscriptionsFeed(fresh: Bool = false) async -> [WebEntry] {
        let channels = library.subscriptions
        let followed = Set(channels.map(\.id))
        if !fresh, let feed, feed.channels == followed, Date().timeIntervalSince(feed.at) < Self.feedLife { return visible(feed.entries) }
        if let running = feedTask { return visible(await running.value.entries) }
        let task = Task.detached(priority: .userInitiated) { await Self.readFeeds(of: channels) }
        feedTask = task
        let (entries, names) = await task.value
        feedTask = nil
        feed = (entries, Date(), followed)
        for (id, name) in names { library.refresh(id, title: name, handle: nil, avatar: nil) }
        let file = Self.feedFile
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entries) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return visible(entries)
    }

    /// The feed without Shorts while the viewer hides them.
    private func visible(_ entries: [WebEntry]) -> [WebEntry] {
        WebSettings.hidesShorts ? entries.filter { !$0.isShort } : entries
    }

    /// Reads every channel's feed and merges them, newest first, with each channel's name as its feed gives it now.
    private nonisolated static func readFeeds(of channels: [WebChannel]) async -> (entries: [WebEntry], names: [String: String]) {
        var entries: [WebEntry] = []
        var names: [String: String] = [:]
        var rest = channels[...]
        while !rest.isEmpty {
            let batch = rest.prefix(8)
            rest = rest.dropFirst(8)
            await withTaskGroup(of: (String, WebFeed?).self) { group in
                for channel in batch {
                    group.addTask {
                        guard let address = WebFeed.address(channelID: channel.id), let data = try? await WebArtwork.data(from: address, timeout: 10)
                        else { return (channel.id, nil) }
                        return (channel.id, WebFeed(atom: data))
                    }
                }
                for await (id, feed) in group {
                    guard let feed else { continue }
                    entries += feed.entries
                    if let name = feed.channel { names[id] = name }
                }
            }
        }
        let newestFirst = entries.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        return (Array(newestFirst.prefix(400)), names)
    }

    // MARK: Beside yt-dlp

    /// The stretches of a YouTube video SponsorBlock's contributors marked; none for other sites or with it off.
    func sponsorSegments(for video: WebVideo) async -> [SponsorBlock.Segment] {
        guard WebSettings.sponsorMode != .off, video.site == "Youtube",
              let address = SponsorBlock.address(videoID: video.id, categories: WebSettings.sponsorCategories) else { return [] }
        guard let data = try? await WebArtwork.data(from: address, timeout: 6) else { return [] }
        return SponsorBlock.segments(for: video.id, in: data)
    }

    /// Fetches a subtitle track into the cache and returns the file, so mpv adds it without waiting on the network.
    func subtitleFile(_ subtitle: WebSubtitle, of video: WebVideo) async -> URL? {
        guard let address = URL(string: subtitle.url) else { return nil }
        let folder = AppPlatform.cachesDirectory.appendingPathComponent("web/subtitles", isDirectory: true)
        let name = "\(video.site)-\(video.id)-\(subtitle.id)".unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
        let file = folder.appendingPathComponent(String(name) + "." + subtitle.format)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let data = try? await WebArtwork.data(from: address), !data.isEmpty else { return nil }
        let saved = await Task.detached(priority: .utility) { () -> Bool in
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
            return (try? data.write(to: file, options: .atomic)) != nil
        }.value
        return saved ? file : nil
    }

    /// What the picker should aim for: the viewer's settings, HDR only on a screen that shows it, and surround only
    /// when the sound output takes more than stereo.
    func preferences(in window: Window?, surround: Bool, audioLanguage: String? = nil, excluded: Set<String> = []) -> WebPlaybackPreferences {
        WebPlaybackPreferences(maximumHeight: WebSettings.quality.maximumHeight, codec: WebSettings.codec,
                               allowsHDR: window?.displayColor?.isHDR ?? false, prefersSurround: surround, audioLanguage: audioLanguage,
                               excluded: excluded)
    }

    /// What to tell the viewer when yt-dlp could not answer.
    static func message(for error: any Error) -> String {
        guard let error = error as? YtDlpError else { return ConnectionError.message(for: error) }
        switch error {
        case .notInstalled:
            return String(localized: "yt-dlp isn’t installed. Install it with your package manager, then try again.",
                          comment: "Web video error: the open-source tool Crucible plays web video through is missing")
        case .botCheck:
            return String(localized: "The site asked to confirm you’re not a bot. Wait a while, or sign in with your browser’s cookies in Settings › Web Video.",
                          comment: "Web video error: the site blocked anonymous playback for now")
        case .signInRequired:
            return String(localized: "This video needs an account. Sign in with your browser’s cookies in Settings › Web Video.",
                          comment: "Web video error: private, members-only or age-restricted video")
        case .unavailable(let reason):
            return reason.isEmpty ? String(localized: "This video isn’t available.", comment: "Web video error") : reason
        case .rateLimited:
            return String(localized: "The site is limiting requests from this connection. Try again in a while.", comment: "Web video error: HTTP 429")
        case .unsupported:
            return String(localized: "yt-dlp doesn’t know how to play this link.", comment: "Web video error: unsupported site or address")
        case .network(let reason):
            return reason.isEmpty ? String(localized: "The site didn’t answer.", comment: "Web video error: network failure") : reason
        case .timedOut:
            return String(localized: "The site took too long to answer.", comment: "Web video error: yt-dlp ran out of time")
        case .malformed:
            return String(localized: "yt-dlp answered in a way Crucible couldn’t read. Updating yt-dlp usually fixes this.",
                          comment: "Web video error: unexpected output")
        case .failed(let reason):
            return String(localized: "yt-dlp couldn’t read this video. Updating yt-dlp usually fixes this.\n\(reason)",
                          comment: "Web video error with yt-dlp's own message on the second line")
        }
    }
}
