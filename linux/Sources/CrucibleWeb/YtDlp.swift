import Foundation

/// yt-dlp on this machine, the open-source extractor every web video comes through: one run per question, answered in
/// JSON. Crucible carries no site's protocol of its own, so when a site changes, updating yt-dlp is the whole fix.
package struct YtDlp: Sendable {
    package let executable: URL
    /// The browser whose cookies every run carries (`--cookies-from-browser`), signing the viewer in; nil for none.
    package var cookiesBrowser: String?

    package init(executable: URL, cookiesBrowser: String? = nil) {
        self.executable = executable
        self.cookiesBrowser = cookiesBrowser
    }

    /// Where yt-dlp is: `CRUCIBLE_YTDLP` when set, else the first `yt-dlp` on `PATH` or in `~/.local/bin`.
    package static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let manager = FileManager.default
        if let chosen = environment["CRUCIBLE_YTDLP"], !chosen.isEmpty {
            return manager.isExecutableFile(atPath: chosen) ? URL(fileURLWithPath: chosen) : nil
        }
        var folders = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":").map(String.init)
        if let home = environment["HOME"] { folders.append(home + "/.local/bin") }
        for folder in folders {
            let path = folder + "/yt-dlp"
            if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// The version yt-dlp reports ("2026.11.16").
    package func version() async throws -> String {
        let output = try await run(["--version"], timeout: .seconds(20), signedIn: false)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything about the video at `address`, with up to `comments` of its comments when asked for.
    package func video(_ address: String, comments: Int = 0) async throws -> WebVideo {
        var arguments = ["-J", "--no-playlist"]
        if comments > 0 {
            arguments += ["--write-comments", "--extractor-args", "youtube:max_comments=\(comments),all,0,0;comment_sort=top"]
        }
        let output = try await run(arguments + ["--", address], timeout: .seconds(comments > 0 ? 90 : 45))
        do {
            return try JSONDecoder().decode(WebVideo.self, from: output)
        } catch {
            throw YtDlpError.malformed
        }
    }

    /// The first `limit` entries of a channel's tab, a playlist, a search (`ytsearch20:words`) or one of the viewer's
    /// own feeds (`:ytsubs`), without opening each video.
    package func listing(_ address: String, limit: Int) async throws -> WebListing {
        let arguments = ["-J", "--flat-playlist", "--playlist-end", String(limit), "--extractor-args", "youtubetab:approximate_date", "--", address]
        let output = try await run(arguments, timeout: .seconds(60))
        do {
            return try JSONDecoder().decode(WebListing.self, from: output)
        } catch {
            throw YtDlpError.malformed
        }
    }

    /// Tells the site the signed-in viewer watched the video at `address`, as its own player would.
    package func markWatched(_ address: String) async throws {
        _ = try await run(["--mark-watched", "--simulate", "--no-playlist", "--", address], timeout: .seconds(45))
    }

    /// Saves the video at `address` into `folder` as one Matroska file, its picture no taller than `maximumHeight`, with
    /// its chapters, its description and the publisher's subtitles inside the file, and returns the file's path. A
    /// download does not take one of the few places kept for questions, which it would hold for as long as it runs.
    package func download(_ address: String, maximumHeight: Int?, into folder: URL) async throws -> String {
        let template = folder.appendingPathComponent("%(title).150B [%(id)s].%(ext)s").path
        var arguments = ["--no-playlist", "--quiet", "--print", "after_move:filepath", "-f", "bv*+ba/b", "--merge-output-format", "mkv",
                         "--embed-chapters", "--embed-metadata", "--embed-subs", "--sub-langs", "all,-live_chat", "--no-overwrites", "-o", template]
        if let maximumHeight { arguments += ["-S", "res:\(maximumHeight)"] }
        let output = try await run(arguments + ["--", address], timeout: .seconds(6 * 3600), gated: false)
        let path = String(decoding: output, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        guard !path.isEmpty else { throw YtDlpError.malformed }
        return path
    }

    /// Runs yt-dlp with `arguments` and returns what it printed, or the reason it gave for failing.
    private func run(_ arguments: [String], timeout: Duration, signedIn: Bool = true, gated: Bool = true) async throws -> Data {
        var full = ["--no-warnings", "--no-progress", "--socket-timeout", "20"]
        if signedIn, let cookiesBrowser, !cookiesBrowser.isEmpty { full += ["--cookies-from-browser", cookiesBrowser] }
        full += arguments
        if gated { await YtDlpGate.shared.enter() }
        let outcome: Result<WebProcess.Output, any Error>
        do {
            outcome = .success(try await WebProcess.run(executable, arguments: full, timeout: timeout))
        } catch {
            outcome = .failure(error)
        }
        if gated { await YtDlpGate.shared.leave() }
        switch outcome {
        case .success(let output):
            guard output.status == 0 else { throw YtDlpError(standardError: output.standardError) }
            return output.standardOutput
        case .failure(WebProcess.Failure.timedOut):
            throw YtDlpError.timedOut
        case .failure(WebProcess.Failure.launch):
            throw YtDlpError.notInstalled
        case .failure(let error):
            throw error
        }
    }
}

/// Why yt-dlp could not answer.
package enum YtDlpError: Error, Equatable, Sendable {
    case notInstalled
    /// The site wants proof the viewer is a person ("Sign in to confirm you’re not a bot").
    case botCheck
    /// The video is private, for members or for adults, and the viewer is not signed in.
    case signInRequired(String)
    case unavailable(String)
    case rateLimited
    case unsupported
    case network(String)
    case timedOut
    case malformed
    case failed(String)

    /// Reads the reason from what yt-dlp wrote before it gave up: its last line that starts with "ERROR:", without the
    /// extractor's name before it and the Python exception after it.
    package init(standardError: String) {
        let lines = standardError.split(whereSeparator: \.isNewline).map(String.init)
        let line = lines.last { $0.hasPrefix("ERROR:") } ?? lines.last ?? ""
        var message = line.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
        if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
            let rest = message[message.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains(" ") {
                message = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                message = rest
            }
        }
        if let cause = message.range(of: " (caused by ") { message = String(message[..<cause.lowerBound]) }
        let lowered = message.lowercased()
        if lowered.contains("not a bot") {
            self = .botCheck
        } else if lowered.contains("http error 429") || lowered.contains("too many requests") || lowered.contains("rate-limited") {
            self = .rateLimited
        } else if lowered.contains("unsupported url") || lowered.contains("is not a valid url") {
            self = .unsupported
        } else if lowered.contains("sign in") || lowered.contains("members-only") || lowered.contains("private video") || lowered.contains("confirm your age")
                    || lowered.contains("cookies") || lowered.contains("log in") || lowered.contains("login required") {
            self = .signInRequired(message)
        } else if lowered.contains("unavailable") || lowered.contains("has been removed") || lowered.contains("not available") || lowered.contains("does not exist")
                    || lowered.contains("terminated") {
            self = .unavailable(message)
        } else if lowered.contains("unable to download") || lowered.contains("timed out") || lowered.contains("name resolution") || lowered.contains("connection")
                    || lowered.contains("network") {
            self = .network(message)
        } else {
            self = .failed(message.isEmpty ? "yt-dlp failed" : message)
        }
    }
}

/// Lets a few yt-dlp runs go at once and queues the rest, so a page of rows never starts a dozen Python processes.
actor YtDlpGate {
    static let shared = YtDlpGate()

    private let limit = 3
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// A list of videos, as a channel's tab, a playlist, a search or a feed gives it.
package struct WebListing: Sendable, Decodable {
    package let id: String?
    package let title: String?
    package let summary: String?
    package let channel: String?
    package let channelID: String?
    package let channelURL: String?
    package let channelHandle: String?
    package let channelFollowers: Int?
    package let isChannelVerified: Bool
    /// The channel's picture, when the listing is a channel's.
    package let avatar: String?
    package let banner: String?
    package let entries: [WebEntry]

    enum CodingKeys: String, CodingKey {
        case id, title, description, channel, uploader, entries, thumbnails
        case channelID = "channel_id"
        case channelURL = "channel_url"
        case uploaderID = "uploader_id"
        case channelFollowers = "channel_follower_count"
        case isChannelVerified = "channel_is_verified"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.text(.id)
        title = container.text(.title)
        summary = container.text(.description)
        channel = container.text(.channel) ?? container.text(.uploader)
        channelID = container.text(.channelID)
        channelURL = container.text(.channelURL)
        channelHandle = container.text(.uploaderID)
        channelFollowers = container.number(.channelFollowers).map { Int($0) }
        isChannelVerified = (try? container.decodeIfPresent(Bool.self, forKey: .isChannelVerified)) ?? false
        let pictures = ((try? container.decodeIfPresent([WebThumbnail].self, forKey: .thumbnails)) ?? nil) ?? []
        avatar = pictures.last { $0.id == "avatar_uncropped" }?.url ?? pictures.filter { $0.isSquare }.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
        banner = pictures.last { $0.id == "banner_uncropped" }?.url ?? pictures.filter { $0.isWide }.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
        let listed = ((try? container.decodeIfPresent([Lossy<ListedEntry>].self, forKey: .entries)) ?? nil)?.compactMap(\.value) ?? []
        let (name, identifier, address) = (channel, channelID, channelURL)
        entries = listed.compactMap { $0.entry(channel: name, channelID: identifier, channelURL: address) }
    }
}

struct WebThumbnail: Sendable, Decodable {
    let url: String
    let id: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case url, id, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        id = container.text(.id)
        width = container.number(.width).map { Int($0) }
        height = container.number(.height).map { Int($0) }
    }

    var isSquare: Bool { width != nil && width == height }
    var isWide: Bool {
        guard let width, let height, height > 0 else { return false }
        return Double(width) / Double(height) > 3
    }
}
