import Foundation

/// Live TV search: channels by name or number, and airings by title or episode, split into what is on now and what airs
/// later. Matching folds case, accents and width, takes every word of the query as the start of a word in the text ("sky
/// f1" finds "SKY SPORTS F1"), and ranks an exact name over a name that starts with the query over a word inside it.
package enum LiveTVSearch {
    package struct Airing: Equatable, Sendable, Identifiable {
        package let program: LiveProgram
        package let channel: LiveChannel
        package var id: String { "\(channel.id)|\(program.id)" }
    }

    package struct Results: Equatable, Sendable {
        package var channels: [LiveChannel] = []
        package var onNow: [Airing] = []
        package var later: [Airing] = []

        package var isEmpty: Bool { channels.isEmpty && onNow.isEmpty && later.isEmpty }
    }

    /// Searches `channels` and their airings for `query`; an empty query finds nothing.
    package static func search(_ query: String, channels: [LiveChannel], programs: (String) -> [LiveProgram], now: Date = Date(),
                               limit: Int = 40) -> Results {
        let words = tokens(query)
        guard !words.isEmpty else { return Results() }
        let typedNumber = query.trimmingCharacters(in: .whitespaces)
        var channelHits: [(LiveChannel, Int, Int)] = []
        var nowHits: [(Airing, Int)] = []
        var laterHits: [(Airing, Int)] = []
        for (index, channel) in channels.enumerated() {
            let label = LiveChannelLabel(channel)
            var best = [score(words, in: label.name), score(words, in: channel.title).map { $0 - 5 }].compactMap { $0 }.max()
            if let number = label.number, number == typedNumber.drop(while: { $0 == "0" }) || number == typedNumber { best = max(best ?? 0, 120) }
            if let best { channelHits.append((channel, best, index)) }
            for program in programs(channel.id) where program.end > now {
                let titleScore = score(words, in: program.title)
                let episodeScore = program.episodeTitle.flatMap { score(words, in: $0) }.map { $0 - 20 }
                guard let best = [titleScore, episodeScore].compactMap({ $0 }).max() else { continue }
                let airing = Airing(program: program, channel: channel)
                if program.start <= now { nowHits.append((airing, best)) } else { laterHits.append((airing, best)) }
            }
        }
        var results = Results()
        results.channels = channelHits.sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }.prefix(limit).map(\.0)
        results.onNow = nowHits.sorted { ($0.1, $1.0.program.start) > ($1.1, $0.0.program.start) }.prefix(limit).map(\.0)
        results.later = firstOfEach(laterHits.sorted { lhs, rhs in
            lhs.0.program.start != rhs.0.program.start ? lhs.0.program.start < rhs.0.program.start : lhs.1 > rhs.1
        }.map(\.0)).prefix(limit).map { $0 }
        return results
    }

    /// Later airings without a title repeated on the same channel (a news hour every hour), keeping the first.
    private static func firstOfEach(_ airings: [Airing]) -> [Airing] {
        var seen = Set<String>()
        return airings.filter { seen.insert("\($0.channel.id)|\(fold($0.program.title))").inserted }
    }

    /// How well `words` match `text`: nil unless every word starts a word of the text (or, from three letters, sits inside
    /// one); 100 for the whole text, 80 when the text starts with the query, 60 when each word starts a word, 40 when one is
    /// only inside a word, less the longer the text is past the query.
    package static func score(_ words: [String], in text: String) -> Int? {
        let folded = fold(text)
        let textWords = folded.split(separator: " ").map(String.init)
        guard !textWords.isEmpty else { return nil }
        var inside = false
        for word in words {
            if textWords.contains(where: { $0.hasPrefix(word) }) { continue }
            if word.count >= 3, textWords.contains(where: { $0.contains(word) }) {
                inside = true
                continue
            }
            return nil
        }
        let query = words.joined(separator: " ")
        let base: Int
        if folded == query {
            base = 100
        } else if folded.hasPrefix(query) {
            base = 80
        } else {
            base = inside ? 40 : 60
        }
        return base - min(max(folded.count - query.count, 0) / 4, 15)
    }

    package static func tokens(_ query: String) -> [String] {
        fold(query).split(separator: " ").map(String.init)
    }

    /// Lowercased without accents or width, every run of anything but letters and digits made one space.
    package static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        var pendingSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
            } else {
                pendingSpace = true
            }
        }
        return out
    }
}

extension LiveTVGuide {
    /// Searches the guide's channels (each station once when copies are merged) and the airings loaded for them.
    package func search(_ query: String, now: Date = Date()) -> LiveTVSearch.Results {
        LiveTVSearch.search(query, channels: channels, programs: { [programs] in programs[$0] ?? [] }, now: now)
    }

    /// Loads the airings of every channel, so a search finds what airs on channels not yet scrolled to.
    package func loadAllPrograms() {
        loadPrograms(for: channels.map(\.id))
    }
}
