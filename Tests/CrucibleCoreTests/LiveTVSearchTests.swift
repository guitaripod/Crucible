import Foundation
import Testing
@testable import CrucibleCore

@Suite("Live TV channel labels")
struct LiveChannelLabelTests {
    @Test(arguments: [
        ("01 US: ESPN", nil, "1", "ESPN", "US", nil),
        ("02 UK: SKY SPORTS F1 FHD", nil, "2", "SKY SPORTS F1", "UK", "FHD"),
        ("UK | BBC One HD", nil, nil, "BBC One", "UK", "HD"),
        ("[DE] Das Erste", nil, nil, "Das Erste", "DE", nil),
        ("4Music", nil, nil, "4Music", nil, nil),
        ("5 Star", "5", "5", "Star", nil, nil),
        ("Film4 +1", "14", "14", "Film4 +1", nil, nil),
        ("CNN", "202", "202", "CNN", nil, nil),
        ("HD", nil, nil, "HD", nil, nil),
        ("46 USA- CNN", nil, "46", "CNN", "USA", nil),
        ("18 US CNN (A)", nil, "18", "CNN (A)", "US", nil),
        ("61 HEVC FHD Sky Sports+", nil, "61", "Sky Sports+", nil, "FHD"),
        ("65 UKFHD | Sky Sports + 50FPS", nil, "65", "Sky Sports +", "UK", "FHD"),
        ("86 DE: SKY SPORT BUNDESLIGA 1", nil, "86", "SKY SPORT BUNDESLIGA 1", "DE", nil),
        ("BBC One", nil, nil, "BBC One", nil, nil),
        ("A-Team TV", nil, nil, "A-Team TV", nil, nil),
        ("Comedy Central", nil, nil, "Comedy Central", nil, nil),
    ] as [(String, String?, String?, String, String?, String?)])
    func splitsTheTitle(title: String, number: String?, wantNumber: String?, name: String, region: String?, quality: String?) {
        let label = LiveChannelLabel(title: title, number: number)
        #expect(label.number == wantNumber)
        #expect(label.name == name)
        #expect(label.region == region)
        #expect(label.quality == quality)
    }

    @Test func tagsListRegionThenQuality() {
        #expect(LiveChannelLabel(title: "03 US: FOX NEWS HD HEVC", number: nil).tags == ["US", "HD"])
    }
}

@Suite("Live TV search")
struct LiveTVSearchTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String, _ title: String, number: String? = nil) -> LiveChannel {
        LiveChannel(id: id, source: LiveSourceID(kind: .playlist, key: "p"), number: number, title: title, stream: .address(URL(string: "http://x.example/\(id)")!, userAgent: nil, referrer: nil))
    }

    private func program(_ id: String, _ channel: String, _ title: String, from start: TimeInterval, hours: Double = 1, episode: String? = nil) -> LiveProgram {
        LiveProgram(id: id, channelID: channel, title: title, episodeTitle: episode, start: now.addingTimeInterval(start),
                    end: now.addingTimeInterval(start + hours * 3600))
    }

    @Test func foldsCaseAccentsAndPunctuation() {
        #expect(LiveTVSearch.fold("  Pokémon: The SÉRIES!! ") == "pokemon the series")
    }

    @Test func everyWordMustStartAWord() {
        #expect(LiveTVSearch.score(["sky", "f1"], in: "SKY SPORTS F1 FHD") != nil)
        #expect(LiveTVSearch.score(["sky", "golf"], in: "SKY SPORTS F1 FHD") == nil)
        #expect(LiveTVSearch.score(["ports"], in: "Sky Sports") != nil)
        #expect(LiveTVSearch.score(["po"], in: "Sky Sports") == nil)
    }

    @Test func exactBeatsPrefixBeatsWord() throws {
        let exact = try #require(LiveTVSearch.score(["espn"], in: "ESPN"))
        let prefix = try #require(LiveTVSearch.score(["espn"], in: "ESPN 2"))
        let word = try #require(LiveTVSearch.score(["espn"], in: "Watch ESPN"))
        #expect(exact > prefix)
        #expect(prefix > word)
    }

    @Test func findsChannelsByNameAndNumberAndSplitsAiringsByTime() {
        let channels = [channel("a", "01 US: ESPN"), channel("b", "02 US: ESPN 2"), channel("c", "CNN", number: "202")]
        let programs = [
            "a": [program("1", "a", "SportsCenter", from: -1800), program("2", "a", "NFL Live", from: 1800)],
            "b": [program("3", "b", "College Football", from: -600), program("4", "b", "SportsCenter", from: 7200)],
            "c": [program("5", "c", "News Hour", from: -100), program("6", "c", "News Hour", from: 3500), program("7", "c", "News Hour", from: 7100)],
        ]
        let lookup = { (id: String) in programs[id] ?? [] }
        let espn = LiveTVSearch.search("espn", channels: channels, programs: lookup, now: now)
        #expect(espn.channels.map(\.id) == ["a", "b"])
        #expect(LiveTVSearch.search("202", channels: channels, programs: lookup, now: now).channels.map(\.id) == ["c"])
        let sports = LiveTVSearch.search("sportscenter", channels: channels, programs: lookup, now: now)
        #expect(sports.onNow.map(\.program.id) == ["1"])
        #expect(sports.later.map(\.program.id) == ["4"])
        let news = LiveTVSearch.search("news", channels: channels, programs: lookup, now: now)
        #expect(news.onNow.map(\.program.id) == ["5"])
        #expect(news.later.map(\.program.id) == ["6"], "a title repeated on one channel is listed once")
        #expect(LiveTVSearch.search("   ", channels: channels, programs: lookup, now: now).isEmpty)
    }

    @Test func endedAiringsAreLeftOut() {
        let channels = [channel("a", "ESPN")]
        let results = LiveTVSearch.search("old", channels: channels, programs: { _ in [self.program("1", "a", "Old Show", from: -7200)] }, now: now)
        #expect(results.onNow.isEmpty && results.later.isEmpty)
    }
}

@Suite("Live TV programme summaries")
struct LiveProgramAboutTests {
    @Test func readsTheAboutFieldOrPlainText() {
        #expect(LiveProgramAbout.text(of: #"{"about":"A **detective** drama."}"#) == "A detective drama.")
        #expect(LiveProgramAbout.text(of: "<think>hm</think>\n A quiz show. ") == "A quiz show.")
        #expect(LiveProgramAbout.text(of: "  ") == nil)
    }

    @Test func theRequestCarriesTheListing() {
        let program = LiveProgram(id: "p", channelID: "c", title: "Columbo", episodeTitle: "Murder by the Book", summary: "A writer is killed.",
                                  start: Date(), end: Date().addingTimeInterval(3600), season: 1, episode: 2, genres: ["Crime"])
        let channel = LiveChannel(id: "c", source: LiveSourceID(kind: .playlist, key: "p"), title: "05 US: MeTV HD", stream: .address(URL(string: "http://x.example")!, userAgent: nil, referrer: nil))
        let input = LiveProgramAbout.input(program, channel: channel)
        #expect(input.contains("Title: Columbo"))
        #expect(input.contains("Episode: Murder by the Book"))
        #expect(input.contains("Season 1, episode 2"))
        #expect(input.contains("Channel: MeTV"))
        #expect(input.contains("Genres: Crime"))
        #expect(input.contains("Listing: A writer is killed."))
    }

    @Test func aQuickAliasTurnsALocalModelsThinkingOff() throws {
        let aliases = #"{"aliases":[{"alias":"quick","max_tokens":100},{"alias":"deep","max_tokens":100,"reasoning":"low"}]}"#
        let prompts = try #require(OpenAICompatiblePrompts(aliasesJSON: Data(aliases.utf8)) { _ in "Say {language}." })
        let brain = OpenAICompatibleBrain(address: URL(string: "http://127.0.0.1:8081")!, model: "m", key: nil, prompts: prompts)
        func body(_ alias: String, plain: Bool = false) throws -> [String: Any] {
            let request = brain.request(for: prompts.aliases[alias]!, alias: alias, input: "x", language: "English", shaped: false, plain: plain)
            return try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        }
        #expect((try body("quick")["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect(try body("deep")["chat_template_kwargs"] == nil)
        #expect(try body("quick", plain: true)["chat_template_kwargs"] == nil)
    }
}
