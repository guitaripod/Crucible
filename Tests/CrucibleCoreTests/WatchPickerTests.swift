import Foundation
import Testing
@testable import CrucibleCore

struct WatchPickerTests {
    private static let heat = WatchTitle(id: "1", kind: .movie, title: "Heat", year: 1995, genres: ["Crime", "Thriller"], minutes: 170, rating: 8.3, contentRating: "R")
    private static let totoro = WatchTitle(id: "2", kind: .movie, title: "My Neighbor Totoro", year: 1988, genres: ["Animation"], minutes: 86, rating: 8.1, contentRating: "G", seen: .seen)
    private static let bear = WatchTitle(id: "3", kind: .show, title: "The Bear", year: 2022, genres: ["Comedy", "Drama"], minutes: 30, rating: 8.6, contentRating: "TV-MA", seen: .started)
    private static let unknown = WatchTitle(id: "4", kind: .movie, title: "Home Video")
    private static let library = [heat, totoro, bear, unknown]

    @Test func aFilmAndASeriesAreReadFromPlexAndNothingElseIs() throws {
        let film = try #require(WatchTitle(DetailFixtures.item(["ratingKey": "10", "type": "movie", "title": "Heat", "year": 1995, "duration": 10_200_000, "audienceRating": 8.3, "rating": 7.0, "contentRating": "R", "viewCount": 2, "addedAt": 50, "Genre": [["tag": "Crime"], ["tag": "Thriller"], ["tag": "Drama"], ["tag": "Action"]]])))
        #expect(film.kind == .movie)
        #expect(film.minutes == 170)
        #expect(film.rating == 8.3)
        #expect(film.genres == ["Crime", "Thriller", "Drama"])
        #expect(film.seen == .seen)
        #expect(film.addedAt == 50)
        let unseen = try #require(WatchTitle(DetailFixtures.item(["ratingKey": "11", "type": "show", "title": "New", "leafCount": 10, "viewedLeafCount": 0])))
        let started = try #require(WatchTitle(DetailFixtures.item(["ratingKey": "12", "type": "show", "title": "Mid", "leafCount": 10, "viewedLeafCount": 4])))
        let done = try #require(WatchTitle(DetailFixtures.item(["ratingKey": "13", "type": "show", "title": "Done", "leafCount": 10, "viewedLeafCount": 10])))
        #expect([unseen.seen, started.seen, done.seen] == [.unseen, .started, .seen])
        #expect(WatchTitle(DetailFixtures.item(["ratingKey": "14", "type": "episode", "title": "Pilot"])) == nil)
        #expect(WatchTitle(DetailFixtures.item(["ratingKey": "15", "type": "collection", "title": "Heists"])) == nil)
    }

    @Test func aPlanIsReadAndEveryFigureIsCheckedBeforeItIsUsed() throws {
        let plan = try #require(WatchPicker.plan(from: #"{"kind":"movie","watched":"unseen","max_minutes":120,"min_minutes":null,"from_year":1990,"to_year":1999,"family":false,"count":3}"#))
        #expect(plan == WatchPlan(kind: .movie, watched: .unseen, maxMinutes: 120, fromYear: 1990, toYear: 1999, count: 3))
        let loose = try #require(WatchPicker.plan(from: #"{"kind":"any","watched":"any","max_minutes":null,"min_minutes":null,"from_year":null,"to_year":null,"family":true,"count":null}"#))
        #expect(loose == WatchPlan(family: true, count: WatchPicker.usualCount))
        let wild = try #require(WatchPicker.plan(from: #"{"kind":"podcast","watched":"maybe","max_minutes":-5,"min_minutes":90000,"from_year":2030,"to_year":1700,"family":false,"count":40}"#))
        #expect(wild == WatchPlan(fromYear: 2030, count: WatchPicker.mostPicks))
        let backwards = try #require(WatchPicker.plan(from: #"{"kind":"any","watched":"any","max_minutes":90,"min_minutes":120,"from_year":1999,"to_year":1990,"family":false,"count":0}"#))
        #expect(backwards == WatchPlan(maxMinutes: 90, fromYear: 1990, toYear: 1999, count: 1))
        #expect(WatchPicker.plan(from: "Sure! Here are some films") == nil)
        #expect(WatchPicker.plan(from: "") == nil)
    }

    @Test func limitsAreAppliedInCodeAndAGapInTheMetadataNeverHidesATitle() {
        #expect(WatchPicker.candidates(for: WatchPlan(kind: .movie), in: Self.library).map(\.id) == ["1", "2", "4"])
        #expect(WatchPicker.candidates(for: WatchPlan(watched: .unseen), in: Self.library).map(\.id) == ["1", "4"])
        #expect(WatchPicker.candidates(for: WatchPlan(watched: .seen), in: Self.library).map(\.id) == ["2", "3"])
        #expect(WatchPicker.candidates(for: WatchPlan(maxMinutes: 120), in: Self.library).map(\.id) == ["2", "3", "4"])
        #expect(WatchPicker.candidates(for: WatchPlan(minMinutes: 150), in: Self.library).map(\.id) == ["1", "4"])
        #expect(WatchPicker.candidates(for: WatchPlan(fromYear: 1990, toYear: 1999), in: Self.library).map(\.id) == ["1", "4"])
        #expect(WatchPicker.candidates(for: WatchPlan(family: true), in: Self.library).map(\.id) == ["2", "4"])
        #expect(WatchPicker.candidates(for: WatchPlan(kind: .show, maxMinutes: 20), in: Self.library).isEmpty)
    }

    @Test func ratingsThatAreNotForChildrenAreKnownAcrossCountries() {
        for rating in ["R", "TV-MA", "gb/18", "de/16", "NC-17", " r "] {
            #expect(WatchPicker.isForAdults(rating), "\(rating)")
        }
        for rating in ["G", "PG", "PG-13", "TV-PG", "TV-Y7", "gb/U", "de/6", "Not Rated", ""] {
            #expect(!WatchPicker.isForAdults(rating), "\(rating)")
        }
        #expect(!WatchPicker.isForAdults(nil))
    }

    @Test func whenMorePassThanCanBeSentTheUnseenAndBetterRatedGoFirst() {
        let many = (1...30).map { number in
            WatchTitle(id: "t\(number)", kind: .movie, title: "Film \(number)", rating: Double(number % 10), seen: number % 3 == 0 ? .seen : .unseen, addedAt: number)
        }
        let kept = WatchPicker.candidates(for: WatchPlan(), in: many, limit: 6)
        #expect(kept.count == 6)
        #expect(kept.allSatisfy { $0.seen == .unseen })
        #expect(kept.map { $0.rating ?? 0 } == kept.map { $0.rating ?? 0 }.sorted(by: >))
        #expect(kept.first?.id == "t29")
        #expect(WatchPicker.candidates(for: WatchPlan(), in: many, limit: 100).map(\.id) == many.map(\.id))
    }

    @Test func theMessageNumbersEachCandidateAndKeepsItsFieldsApart() {
        let odd = WatchTitle(id: "9", kind: .movie, title: "Face|Off\nPart 2", year: 1997, genres: ["Action"], minutes: 138, rating: 7.34, contentRating: "R", seen: .seen)
        #expect(WatchPicker.digestLine(Self.heat, number: 1) == "1|Heat|1995|movie|Crime, Thriller|170|8.3|R|")
        #expect(WatchPicker.digestLine(odd, number: 7) == "7|Face Off Part 2|1997|movie|Action|138|7.3|R|seen")
        #expect(WatchPicker.digestLine(Self.unknown, number: 4) == "4|Home Video||movie|||||")
        #expect(WatchPicker.digestLine(Self.bear, number: 3).hasSuffix("|TV-MA|started"))
        let message = WatchPicker.pickInput("  something\ntense | now ", plan: WatchPlan(family: true, count: 3), candidates: [Self.heat, Self.totoro])
        #expect(message == "They asked: something tense   now\nChildren will be watching.\nChoose up to 3.\nTitles:\n1|Heat|1995|movie|Crime, Thriller|170|8.3|R|\n2|My Neighbor Totoro|1988|movie|Animation|86|8.1|G|seen")
        #expect(WatchPicker.planInput("a heist", year: 2026) == "Year now: 2026\nThey asked: a heist")
        #expect(WatchPicker.cleaned(String(repeating: "a", count: 900)).count == WatchPicker.longestRequest)
    }

    @Test func aMessageNeverPassesWhatTheServiceTakes() {
        let many = (1...3_000).map { WatchTitle(id: "\($0)", kind: .movie, title: String(repeating: "Long Title ", count: 8) + "\($0)", year: 2000, genres: ["Drama", "Mystery"], minutes: 120, rating: 7.0) }
        let message = WatchPicker.pickInput("anything", plan: WatchPlan(), candidates: many)
        #expect(message.count <= WatchPicker.inputBudget)
        #expect(message.count > WatchPicker.inputBudget - 200)
        #expect(!message.hasSuffix("\n"))
    }

    @Test func picksAreOnlyEverTitlesThatWereSent() throws {
        let candidates = [Self.heat, Self.totoro, Self.bear]
        let reply = #"{"picks":[{"id":2,"why":"Gentle and warm.\nSecond line"},{"id":9,"why":"Not in the list"},{"id":2,"why":"Again"},{"id":0,"why":"Zero"},{"id":1,"why":"Tense."},{"id":3,"why":"Sharp."}],"note":" Your library has little else. "}"#
        let chosen = try #require(WatchPicker.picks(from: reply, candidates: candidates, plan: WatchPlan(count: 2)))
        #expect(chosen.picks.map(\.title.id) == ["2", "1"])
        #expect(chosen.picks.first?.why == "Gentle and warm. Second line")
        #expect(chosen.note == "Your library has little else.")
        let long = #"{"picks":[{"id":1,"why":"\#(String(repeating: "x", count: 500))"}],"note":""}"#
        #expect(try #require(WatchPicker.picks(from: long, candidates: candidates, plan: WatchPlan())).picks.first?.why.count == 160)
        #expect(try #require(WatchPicker.picks(from: #"{"picks":[],"note":"Nothing fits."}"#, candidates: candidates, plan: WatchPlan())).picks.isEmpty)
        #expect(WatchPicker.picks(from: "I would suggest Heat.", candidates: candidates, plan: WatchPlan()) == nil)
    }
}

struct WatchSessionTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(alias: String, input: String)] = []
        private var loads = 0

        func note(_ alias: String, _ input: String) { lock.withLock { asked.append((alias, input)) } }
        func noteLoad() { lock.withLock { loads += 1 } }
        var aliases: [String] { lock.withLock { asked.map(\.alias) } }
        var inputs: [String] { lock.withLock { asked.map(\.input) } }
        var loadCount: Int { lock.withLock { loads } }
    }

    private static let items = [
        DetailFixtures.item(["ratingKey": "10", "type": "movie", "title": "Heat", "year": 1995, "duration": 10_200_000]),
        DetailFixtures.item(["ratingKey": "11", "type": "movie", "title": "Moon", "year": 2009, "duration": 5_820_000]),
        DetailFixtures.item(["ratingKey": "12", "type": "show", "title": "The Bear", "year": 2022, "duration": 1_800_000, "leafCount": 28, "viewedLeafCount": 0]),
    ]

    private static func session(
        _ calls: Calls, items: [PlexMetadata] = items, loadFails: Bool = false, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) },
        answer: @escaping @Sendable (String, String) throws(HostedBrainError) -> String
    ) -> WatchSession {
        WatchSession(environment: WatchSession.Environment(
            loadLibrary: {
                calls.noteLoad()
                if loadFails { throw URLError(.cannotConnectToHost) }
                return items
            },
            ask: { alias, input async throws(HostedBrainError) in
                calls.note(alias, input)
                return try answer(alias, input)
            },
            year: { 2026 }, now: now))
    }

    private static let anyPlan = #"{"kind":"any","watched":"any","max_minutes":null,"min_minutes":null,"from_year":null,"to_year":null,"family":false,"count":null}"#

    @Test func aSentenceBecomesPicksThroughAPlanAndAChoice() async throws {
        let calls = Calls()
        let steps = Calls()
        let session = Self.session(calls) { alias, _ throws(HostedBrainError) in
            alias == WatchPicker.planAlias
                ? #"{"kind":"movie","watched":"any","max_minutes":120,"min_minutes":null,"from_year":null,"to_year":null,"family":false,"count":2}"#
                : #"{"picks":[{"id":1,"why":"Quiet and strange."}],"note":""}"#
        }
        let answer = try await session.answer("something quiet under two hours") { steps.note("\($0)", "") }.get()
        #expect(calls.aliases == [WatchPicker.planAlias, WatchPicker.pickAlias])
        #expect(calls.inputs[0] == "Year now: 2026\nThey asked: something quiet under two hours")
        #expect(calls.inputs[1] == "They asked: something quiet under two hours\nChoose up to 2.\nTitles:\n1|Moon|2009|movie||97|||")
        #expect(steps.aliases == ["readingLibrary", "understanding", "choosing"])
        #expect(answer.picks.map(\.title.title) == ["Moon"])
        #expect(answer.picks.first?.why == "Quiet and strange.")
        #expect(answer.item(for: answer.picks[0])?.id == "11")
        #expect(answer.request == "something quiet under two hours")
    }

    @Test func nothingIsAskedOfTheModelWhenTheLibraryCannotAnswer() async {
        let empty = Calls()
        #expect(await Self.session(empty, items: []) { _, _ throws(HostedBrainError) in "" }.answer("x") { _ in } .failure == .emptyLibrary)
        #expect(empty.aliases.isEmpty)
        let down = Calls()
        #expect(await Self.session(down, loadFails: true) { _, _ throws(HostedBrainError) in "" }.answer("x") { _ in }.failure == .libraryUnreachable)
        #expect(down.aliases.isEmpty)
    }

    @Test func limitsThatLeaveNothingAndChoicesOfNothingBothSayNothingFits() async {
        let strict = Calls()
        let plan = #"{"kind":"movie","watched":"any","max_minutes":null,"min_minutes":null,"from_year":1920,"to_year":1929,"family":false,"count":null}"#
        #expect(await Self.session(strict) { _, _ throws(HostedBrainError) in plan }.answer("a silent western") { _ in }.failure == .nothingFits(note: ""))
        #expect(strict.aliases == [WatchPicker.planAlias])
        let none = Calls()
        let session = Self.session(none) { alias, _ throws(HostedBrainError) in
            alias == WatchPicker.planAlias ? Self.anyPlan : #"{"picks":[],"note":"Your library has no westerns."}"#
        }
        #expect(await session.answer("a western") { _ in }.failure == .nothingFits(note: "Your library has no westerns."))
    }

    @Test func aRefusalOrAnUnreadableReplyIsAFailureOfItsOwnKind() async {
        for error in [HostedBrainError.offline, .needsPro, .busy, .allowanceUsed(resetsAt: Date(timeIntervalSince1970: 60))] {
            #expect(await Self.session(Calls()) { _, _ throws(HostedBrainError) in throw error }.answer("x") { _ in }.failure == .brain(error))
        }
        #expect(await Self.session(Calls()) { _, _ throws(HostedBrainError) in "not json" }.answer("x") { _ in }.failure == .brain(.failed))
        let half = Self.session(Calls()) { alias, _ throws(HostedBrainError) in
            if alias == WatchPicker.planAlias { return Self.anyPlan }
            throw .offline
        }
        #expect(await half.answer("x") { _ in }.failure == .brain(.offline))
    }

    @Test func theLibraryIsReadOnceAndAgainAfterTenMinutes() async {
        let calls = Calls()
        let clock = Calls()
        let session = Self.session(calls, now: { Date(timeIntervalSince1970: Double(clock.loadCount) * 400) }) { alias, _ throws(HostedBrainError) in
            alias == WatchPicker.planAlias ? Self.anyPlan : #"{"picks":[{"id":1,"why":"Good."}],"note":""}"#
        }
        _ = await session.answer("one") { _ in }
        clock.noteLoad()
        _ = await session.answer("two") { _ in }
        #expect(calls.loadCount == 1)
        clock.noteLoad()
        _ = await session.answer("three") { _ in }
        #expect(calls.loadCount == 2)
    }
}

struct DescribedRecapTests {
    private static func episode(_ number: Int, season: Int = 1, watched: Bool, summary: String?) -> PlexMetadata {
        var fields: [String: Any] = ["ratingKey": "e\(season)\(number)", "type": "episode", "title": "Chapter \(number)", "index": number, "parentIndex": season]
        if watched { fields["viewCount"] = 1 }
        if let summary { fields["summary"] = summary }
        return DetailFixtures.item(fields)
    }

    private static func model(_ episodes: [PlexMetadata]) -> ShowDetailModel {
        ShowDetailModel(show: DetailFixtures.item(["ratingKey": "s", "type": "show", "title": "The Crew", "summary": "Four thieves and one last job."]), episodes: episodes, allEpisodes: episodes)
    }

    @Test func theLastThreeFinishedEpisodesWithADescriptionAreUsedOldestFirst() {
        let model = Self.model([
            Self.episode(1, watched: true, summary: "One."), Self.episode(2, watched: true, summary: "Two."), Self.episode(3, watched: true, summary: "  "),
            Self.episode(4, watched: true, summary: "Four."), Self.episode(5, watched: true, summary: "Five."), Self.episode(6, watched: false, summary: "Six."),
            Self.episode(7, watched: true, summary: "Seven, watched out of order."),
        ])
        let episodes = DescribedRecap.episodes(of: model)
        #expect(episodes.map(\.code) == ["S1 · E2", "S1 · E4", "S1 · E5"])
        #expect(episodes.map(\.description) == ["Two.", "Four.", "Five."])
        #expect(DescribedRecap.basis(episodes) == "From the descriptions of S1 · E2 to S1 · E5")
        #expect(DescribedRecap.basis(Array(episodes.suffix(1))) == "From the description of S1 · E5")
        #expect(DescribedRecap.episodes(of: Self.model([Self.episode(1, watched: false, summary: "One.")])).isEmpty)
        #expect(DescribedRecap.episodes(of: Self.model([Self.episode(1, watched: true, summary: nil)])).isEmpty)
    }

    @Test func aShowOffersItsServerThenItsDescriptionsThenNothing() {
        CompanionStore.forget()
        #expect(PreviouslyOnRequest.offer(Self.model([Self.episode(1, watched: true, summary: "One."), Self.episode(2, watched: false, summary: "Two.")])) == .descriptions)
        #expect(PreviouslyOnRequest.offer(Self.model([Self.episode(1, watched: true, summary: nil)])) == .none)
        #expect(PreviouslyOnRequest.offer(Self.model([Self.episode(1, watched: false, summary: "One.")])) == .none)
    }

    @Test func theMessageHoldsTheSeriesAndItsEpisodesAndNothingThatBreaksALine() {
        let episodes = [
            DescribedEpisode(id: "a", code: "S1 · E1", title: "Pilot", description: "They meet.\nThey plan."),
            DescribedEpisode(id: "b", code: "S1 · E2", title: "The \"Job\"", description: String(repeating: "x", count: 2_000)),
        ]
        let message = DescribedRecap.input(show: "The Crew", about: "Four thieves\nand one last job.", episodes: episodes)
        let lines = message.components(separatedBy: "\n")
        #expect(lines.count == 5)
        #expect(lines[0] == "Series: The Crew")
        #expect(lines[1] == "About it: Four thieves and one last job.")
        #expect(lines[2] == "Episodes they finished, oldest first:")
        #expect(lines[3] == "S1 · E1 \"Pilot\": They meet. They plan.")
        #expect(lines[4].count == "S1 · E2 \"The \"Job\"\": ".count + 900)
        #expect(!DescribedRecap.input(show: "The Crew", about: " ", episodes: episodes).contains("About it"))
    }

    @Test func aRecapIsTakenOnlyWhenItIsOneWorthShowing() {
        let good = "The crew pulled off the first job and paid for it at once."
        #expect(DescribedRecap.recap(from: #"{"recap":"  \#(good)  "}"#) == good)
        #expect(DescribedRecap.recap(from: #"{"recap":"Too short."}"#) == nil)
        #expect(DescribedRecap.recap(from: #"{"recap":"\#(String(repeating: "word ", count: 400))"}"#) == nil)
        #expect(DescribedRecap.recap(from: good) == nil)
        #expect(DescribedRecap.recap(from: #"{"summary":"\#(good)"}"#) == nil)
    }

    @Test func theLanguageSentIsItsEnglishNameInTheCharactersTheServiceTakes() {
        #expect(HostedBrain.languageName("fi") == "Finnish")
        #expect(HostedBrain.languageName("pt-BR") == "Portuguese (Brazil)")
        #expect(HostedBrain.languageName("zh-Hans") == "Chinese, Simplified")
        #expect(HostedBrain.languageName("en") == "English")
    }

    @Test func theScriptedModelAnswersInTheShapesTheServiceUses() throws {
        let plan = try #require(WatchPicker.plan(from: ScriptedHostedBrain.answer(alias: WatchPicker.planAlias, input: "")))
        #expect(plan == WatchPlan())
        let candidates = (1...6).map { WatchTitle(id: "\($0)", kind: .movie, title: "Film \($0)") }
        let reply = ScriptedHostedBrain.answer(alias: WatchPicker.pickAlias, input: WatchPicker.pickInput("x", plan: plan, candidates: candidates))
        #expect(try #require(WatchPicker.picks(from: reply, candidates: candidates, plan: plan)).picks.map(\.title.id) == ["1", "2", "3", "4"])
        #expect(DescribedRecap.recap(from: ScriptedHostedBrain.answer(alias: DescribedRecap.alias, input: "")) != nil)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
