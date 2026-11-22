import Foundation
import Testing

@testable import CrucibleCore

@Suite("Live TV duplicate channels")
struct LiveChannelMergeTests {
    private static let first = LiveSourceID(kind: .playlist, key: "a")
    private static let second = LiveSourceID(kind: .playlist, key: "b")
    private static let tuner = LiveSourceID(kind: .plexDVR, key: "m.1")

    private static func channel(_ id: String, _ title: String, source: LiveSourceID = first, guideKey: String? = nil, number: String? = nil,
                                groups: [String] = [], logo: URL? = nil) -> LiveChannel {
        let stream: LiveStream = switch source.kind {
        case .plexDVR: .plexDVR(dvrKey: "1", channel: id)
        case .plexFree: .plexFree(partKey: id)
        case .playlist: .address(URL(string: "https://s.example/\(id)")!, userAgent: nil, referrer: nil)
        }
        return LiveChannel(id: id, source: source, number: number, title: title, logo: logo, groups: groups, guideKey: guideKey ?? title, stream: stream)
    }

    private static func titles(_ result: LiveChannelMerge.Result) -> [String] { result.channels.map(\.title) }

    @Test func foldsQualityAndFeedVariantsKeepingTheSharpest() {
        let result = LiveChannelMerge.merge([
            Self.channel("1", "CNN"), Self.channel("2", "CNN HD"), Self.channel("3", "CNN FHD (Backup)"), Self.channel("4", "BBC News"),
        ])
        #expect(Self.titles(result) == ["CNN FHD (Backup)", "BBC News"])
        #expect(result.alternates["3"]?.map(\.id) == ["2", "1"])
        #expect(result.canonical == ["1": "3", "2": "3"])
    }

    @Test func foldsAcrossSourcesAndMergesWhatCopiesAdd() {
        let logo = URL(string: "https://logo.example/espn.png")!
        let result = LiveChannelMerge.merge([
            Self.channel("a", "01 US: ESPN", groups: ["Sports"]),
            Self.channel("b", "US | ESPN ᴴᴰ", source: Self.second, number: "206", groups: ["USA"], logo: logo),
        ])
        #expect(result.channels.count == 1)
        let kept = result.channels[0]
        #expect(kept.id == "b")
        #expect(kept.groups == ["USA", "Sports"])
        #expect(kept.logo == logo)
        #expect(kept.number == "206")
    }

    @Test func keepsRegionsTimeshiftsAndRegionalEditionsApart() {
        let result = LiveChannelMerge.merge([
            Self.channel("1", "UK: Discovery"), Self.channel("2", "US: Discovery"), Self.channel("3", "Discovery"),
            Self.channel("4", "Film4"), Self.channel("5", "Film4 +1"),
            Self.channel("6", "BBC One London", guideKey: "BBCOne.uk"), Self.channel("7", "BBC One Scotland", guideKey: "BBCOne.uk"),
            Self.channel("8", "ESPN-2"), Self.channel("9", "ESPN 2"),
        ])
        #expect(Self.titles(result) == ["UK: Discovery", "US: Discovery", "Discovery", "Film4", "Film4 +1", "BBC One London", "BBC One Scotland", "ESPN-2"])
    }

    @Test func joinsByGuideIdAndSpeltNumbers() {
        let result = LiveChannelMerge.merge([
            Self.channel("1", "BBC One", source: Self.first), Self.channel("2", "BBC 1 HD", source: Self.second),
            Self.channel("3", "Das Erste", guideKey: "daserste.de"), Self.channel("4", "ARD", source: Self.second, guideKey: "daserste.de"),
            Self.channel("5", "Film4", guideKey: "film4.uk"), Self.channel("6", "Film4 +1", source: Self.second, guideKey: "film4.uk"),
        ])
        #expect(Self.titles(result) == ["BBC 1 HD", "Das Erste", "Film4", "Film4 +1"])
    }

    @Test func prefersATunerAndNeverFoldsTwoOfItsChannels() {
        let result = LiveChannelMerge.merge([
            Self.channel("p", "KQED HD"), Self.channel("t1", "KQED", source: Self.tuner), Self.channel("t2", "KQED", source: Self.tuner),
        ])
        #expect(result.channels.map(\.id) == ["t1", "t2"])
        #expect(result.alternates["t1"]?.map(\.id) == ["p"])
    }

    @Test func leavesNamesThatAreOnlyMarksAlone() {
        let result = LiveChannelMerge.merge([Self.channel("1", "HD"), Self.channel("2", "4K"), Self.channel("3", "5 Star"), Self.channel("4", "Star")])
        #expect(result.channels.count == 4)
    }
}
