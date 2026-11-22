import Foundation
import MidgarCore

/// A few sentences on what an airing's programme is, asked of the person's own model (`livetv.about.v1`) when the pointer
/// rests on it in the guide. The answer is kept per programme for the session, so moving back over it answers at once, and
/// one request runs per programme however often it is hovered.
package actor LiveProgramAbout {
    package static let alias = "livetv.about.v1"
    package static let shared = LiveProgramAbout()

    private var answers: [String: String] = [:]
    private var running: [String: Task<String?, Never>] = [:]

    /// Whether a model is set up to ask.
    package static var isAvailable: Bool { HostedBrain.isAvailable && HostedBrain.takesAnyRequest }

    /// The answer already in hand for `program`, without asking.
    package func cached(_ program: LiveProgram) -> String? {
        answers[Self.key(program)]
    }

    /// The model's few sentences on `program`, nil when no model answers.
    package func about(_ program: LiveProgram, channel: LiveChannel?) async -> String? {
        let key = Self.key(program)
        if let answer = answers[key] { return answer }
        if let task = running[key] { return await task.value }
        let input = Self.input(program, channel: channel)
        let task = Task<String?, Never> {
            do {
                let reply = try await HostedBrain.ask(alias: Self.alias, input: input)
                return Self.text(of: reply)
            } catch {
                MidgarLog.notice("No word on \(program.title): \(error)", category: .liveTV)
                return nil
            }
        }
        running[key] = task
        let answer = await task.value
        running[key] = nil
        if let answer { answers[key] = answer }
        return answer
    }

    /// The request: the title, the episode, the channel, the genres and the listing's description, one per line.
    package static func input(_ program: LiveProgram, channel: LiveChannel?) -> String {
        var lines = ["Title: \(program.title)"]
        if let episode = program.episodeTitle, !episode.isEmpty { lines.append("Episode: \(episode)") }
        if let season = program.season, let number = program.episode { lines.append("Season \(season), episode \(number)") }
        if let channel { lines.append("Channel: \(LiveChannelLabel(channel).name)") }
        if !program.genres.isEmpty { lines.append("Genres: \(program.genres.joined(separator: ", "))") }
        if let summary = program.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("Listing: \(summary.prefix(800))")
        }
        return lines.joined(separator: "\n")
    }

    /// The sentences in a reply: the `about` field of its JSON, or the text itself from a model that wrote no JSON.
    package static func text(of reply: String) -> String? {
        if let data = reply.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let about = object["about"] as? String {
            return clean(about)
        }
        var body = reply
        if let close = body.range(of: "</think>", options: .backwards) { body = String(body[close.upperBound...]) }
        return clean(body)
    }

    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "**", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The programme a summary describes: its title and episode, so every airing of one episode shares an answer.
    private static func key(_ program: LiveProgram) -> String {
        "\(LiveTVSearch.fold(program.title))|\(LiveTVSearch.fold(program.episodeTitle ?? ""))"
    }
}
