import Foundation
import MidgarCore

/// One finished episode as a described Previously On shows it. Only its description is sent.
package struct DescribedEpisode: Equatable, Sendable, Identifiable {
    package let id: String
    /// "S2 · E4", or the episode's title when it has no number.
    package let code: String
    package let title: String
    package let description: String
}

/// A Previously On without Crucible Server: the last finished episodes' own descriptions from Plex, shown as they
/// are, and written into one recap when the person asks for that, by Apple Intelligence on the device where it can and
/// by Crucible's hosted model otherwise. Only the name of the
/// series and those descriptions are sent. With Crucible Server the recap comes from what was said.
package enum DescribedRecap {
    package static let alias = "recap.describe.v1"
    package static let episodeCount = 3
    private static let longestDescription = 900
    private static let longestRecap = 1_200

    /// The last finished episodes before the next one that have a description, oldest first. Specials are left out:
    /// they sit before the first season whenever they were watched, and seldom carry the story.
    package static func episodes(of model: ShowDetailModel) -> [DescribedEpisode] {
        let all = model.allEpisodes.isEmpty ? model.episodes : model.allEpisodes
        let finished = Set(PreviouslyOn.finished(in: all, before: model.upNext?.episode))
        return EpisodeOrder.sorted(all)
            .filter { finished.contains($0.id) && $0.parentIndex != 0 }
            .compactMap { episode -> DescribedEpisode? in
                guard let summary = episode.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
                let code = DetailFormat.episodeCode(season: episode.parentIndex, episode: episode.index) ?? episode.title
                return DescribedEpisode(id: episode.id, code: code, title: episode.title, description: summary)
            }
            .suffix(episodeCount)
            .map { $0 }
    }

    /// The message the recap alias reads: the name of the series and each episode's description, numbered in order.
    package static func input(show: String, episodes: [DescribedEpisode]) -> String {
        let oneLine: (String, Int) -> String = { text, limit in
            String(text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(limit))
        }
        var message = "Series: \(oneLine(show, 160))\n"
        message += "Episodes they finished, oldest first:"
        for (place, episode) in episodes.enumerated() {
            message += "\n\(place + 1). \(oneLine(episode.description, longestDescription))"
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

    /// Whether a recap of these episodes can be asked for: wherever Crucible's AI answers, and in the demo only for
    /// the episodes it holds a prepared recap of.
    package static func canWrite(show: String, episodes: [DescribedEpisode]) -> Bool {
        !episodes.isEmpty && HostedBrain.canAnswer(alias: alias, input: input(show: show, episodes: episodes))
    }

    /// The recap of these episodes, written by the device's own model or the hosted one.
    package static func write(show: String, episodes: [DescribedEpisode]) async throws(HostedBrainError) -> String {
        let reply = try await HostedBrain.ask(alias: alias, input: input(show: show, episodes: episodes))
        guard let recap = recap(from: reply) else { throw .failed }
        return recap
    }

    /// A recap as a viewer given a taste of it reads it: how it begins, and the rest that Crucible Pro opens.
    package struct Taste: Equatable, Sendable {
        package let opening: String
        package let rest: String
    }

    /// Where a recap shown in part stops: after the first sentence that ends past `earliestCut` of the text, as long as it
    /// ends before `latestCut`, so the opening says something and most of the recap is still to come.
    private static let earliestCut = 0.2
    private static let latestCut = 0.6
    private static let cutWithoutSentence = 0.4
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "।", "۔"]
    /// Sentence ends that need no space after them, as Chinese and Japanese write theirs.
    private static let unspacedSentenceEnds: Set<Character> = ["。", "！", "？"]

    /// Splits a recap for a taste. One written as a single long sentence is cut at a word, or mid-run in a script that
    /// writes none apart, and its opening ends in an ellipsis. A recap too short to split comes back whole.
    package static func taste(of recap: String) -> Taste {
        let characters = Array(recap)
        guard characters.count >= 2 else { return Taste(opening: recap, rest: "") }
        let earliest = Int(Double(characters.count) * earliestCut)
        let latest = Int(Double(characters.count) * latestCut)
        let cut = sentenceCut(in: characters, from: earliest, to: latest)
        if let cut { return split(characters, at: cut, elided: false) }
        return split(characters, at: wordCut(in: characters), elided: true)
    }

    /// The offset just past the first sentence end between `earliest` and `latest`, or nil when no sentence ends there.
    private static func sentenceCut(in characters: [Character], from earliest: Int, to latest: Int) -> Int? {
        guard earliest < latest else { return nil }
        for place in max(earliest, 1)..<latest where sentenceEnds.contains(characters[place - 1]) {
            let next = characters[place]
            if sentenceEnds.contains(next) { continue }
            if next.isWhitespace || unspacedSentenceEnds.contains(characters[place - 1]) { return place }
        }
        return nil
    }

    /// The offset of the last space before `cutWithoutSentence` of the text, or that point itself in a run with no space.
    private static func wordCut(in characters: [Character]) -> Int {
        let limit = max(1, Int(Double(characters.count) * cutWithoutSentence))
        return characters[..<limit].lastIndex(where: \.isWhitespace) ?? limit
    }

    private static func split(_ characters: [Character], at cut: Int, elided: Bool) -> Taste {
        let opening = String(characters[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(characters[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opening.isEmpty, !rest.isEmpty else { return Taste(opening: String(characters), rest: "") }
        return Taste(opening: elided ? opening + "…" : opening, rest: rest)
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
    /// What writing a recap sends, or in the demo that it sends nothing.
    package static var sends: String {
        guard HostedBrain.takesAnyRequest else {
            return String(localized: "In the demo this recap was prepared ahead, and nothing leaves this device.", comment: "Shown in the demo in place of what a recap sends")
        }
        switch HostedBrain.route(for: [DescribedRecap.alias]) {
        case .onDevice:
            return String(localized: "Apple Intelligence writes the recap on this device from these descriptions. Nothing leaves it.", comment: "What a described Previously On sends when the device's own model writes it")
        case .onDeviceFirst:
            return String(localized: "Apple Intelligence writes the recap on this device. Only if it can't write it are the name of the series and these descriptions sent to Crucible's AI. Nothing else leaves this device.", comment: "What a described Previously On sends when the device's own model writes it and the hosted model is the fallback")
        case .hosted:
            return String(localized: "Writing a recap sends the name of the series and these descriptions to Crucible's AI. Nothing else leaves this device.", comment: "What a described Previously On sends to the hosted model")
        }
    }
    package static let withServer = String(localized: "With Crucible Server on the computer with Plex, it is written from what was said in the episodes.", comment: "Hint under a Previously On made from descriptions")
    /// Under how a recap begins, for a viewer without Crucible Pro who was given a taste of it.
    package static let sealedNote = String(localized: "This is how your recap begins. Crucible Pro opens the rest of it, and writes one for every series you watch.", comment: "Under the opening of a recap whose rest is sealed until Crucible Pro is on")
    package static let readWhole = String(localized: "Read the Whole Recap", comment: "Button under the opening of a recap that opens the paywall for the rest")

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
        case .unavailableInRegion:
            return MidgarModelRegion.unavailableMessage
        }
    }
}
