import Foundation

/// One finished episode as a described Previously On shows it and sends it.
package struct DescribedEpisode: Equatable, Sendable, Identifiable {
    package let id: String
    /// "S2 · E4", or the episode's title when it has no number.
    package let code: String
    package let title: String
    package let description: String
}

/// A Previously On without Crucible Server: the last finished episodes' own descriptions from Plex, shown as they
/// are, and written into one recap by Crucible's hosted model when the person asks for that. Only the name of the
/// series, a line about it and those descriptions are sent. With Crucible Server the recap comes from what was said.
package enum DescribedRecap {
    package static let alias = "recap.describe.v1"
    package static let episodeCount = 3
    private static let longestDescription = 900
    private static let longestAbout = 500
    private static let longestRecap = 1_200

    /// The last finished episodes before the next one that have a description, oldest first.
    package static func episodes(of model: ShowDetailModel) -> [DescribedEpisode] {
        let all = model.allEpisodes.isEmpty ? model.episodes : model.allEpisodes
        let finished = Set(PreviouslyOn.finished(in: all, before: model.upNext?.episode))
        return EpisodeOrder.sorted(all)
            .filter { finished.contains($0.id) }
            .compactMap { episode -> DescribedEpisode? in
                guard let summary = episode.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
                let code = DetailFormat.episodeCode(season: episode.parentIndex, episode: episode.index) ?? episode.title
                return DescribedEpisode(id: episode.id, code: code, title: episode.title, description: summary)
            }
            .suffix(episodeCount)
            .map { $0 }
    }

    /// The message the recap alias reads.
    package static func input(show: String, about: String?, episodes: [DescribedEpisode]) -> String {
        let oneLine: (String, Int) -> String = { text, limit in
            String(text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(limit))
        }
        var message = "Series: \(oneLine(show, 160))\n"
        if let about, !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message += "About it: \(oneLine(about, longestAbout))\n" }
        message += "Episodes they finished, oldest first:"
        for episode in episodes {
            message += "\n\(oneLine(episode.code, 20)) \"\(oneLine(episode.title, 120))\": \(oneLine(episode.description, longestDescription))"
        }
        return message
    }

    /// The recap of a reply, or nil when the reply holds none worth showing.
    package static func recap(from reply: String) -> String? {
        struct Wire: Decodable {
            let recap: String
        }
        guard let data = reply.data(using: .utf8), let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        let text = wire.recap.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20, text.count <= longestRecap else { return nil }
        return text
    }

    /// The recap of these episodes, written by the hosted model.
    package static func write(show: String, about: String?, episodes: [DescribedEpisode]) async throws(HostedBrainError) -> String {
        let reply = try await HostedBrain.ask(alias: alias, input: input(show: show, about: about, episodes: episodes))
        guard let recap = recap(from: reply) else { throw .failed }
        return recap
    }

    /// "From the descriptions of S1 · E3 to S1 · E5", or the one episode when there was only one.
    package static func basis(_ episodes: [DescribedEpisode]) -> String {
        guard let first = episodes.first?.code, let last = episodes.last?.code else { return "" }
        if first == last { return String(localized: "From the description of \(first)", comment: "What a recap draws on, e.g. From the description of S1 · E5") }
        return String(localized: "From the descriptions of \(first) to \(last)", comment: "What a recap draws on, e.g. From the descriptions of S1 · E3 to S1 · E5")
    }
}

/// The words of a Previously On that comes from episode descriptions.
package enum DescribedRecapCopy {
    package static let write = String(localized: "Write a Recap", comment: "Button that asks for episode descriptions to be written into one recap")
    package static let readDescriptions = String(localized: "Read the Descriptions", comment: "Apple TV button that shows the last episodes' descriptions")
    package static let writing = String(localized: "Writing the recap…", comment: "Shown while a recap is being written")
    package static let sends = String(localized: "Writing a recap sends the name of the series and these descriptions to Crucible's AI. Nothing else leaves this device.", comment: "What a described Previously On sends to the hosted model")
    package static let withServer = String(localized: "With Crucible Server on the computer with Plex, it is written from what was said in the episodes.", comment: "Hint under a Previously On made from descriptions")

    package static func failure(_ error: HostedBrainError) -> String {
        switch error {
        case .unavailable:
            return String(localized: "This build of Crucible can't write a recap.")
        case .offline:
            return String(localized: "Couldn't write the recap because Crucible's AI couldn't be reached. Check your connection and try again.")
        case .needsPro:
            return String(localized: "Couldn't write the recap because that comes with Crucible Pro.")
        case .allowanceUsed(let resetsAt):
            let time = resetsAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "Couldn't write the recap because today's AI allowance is used up. It comes back at \(time).", comment: "The placeholder is a time of day, e.g. 2:00")
        case .busy:
            return String(localized: "Couldn't write the recap because Crucible's AI is busy. Try again in a minute.")
        case .declined, .failed:
            return String(localized: "Couldn't write the recap because Crucible's AI is unavailable right now. Try again in a few minutes.")
        }
    }
}
