import Foundation
import Testing

@testable import CrucibleCore

@Suite("Live TV playlists and guides")
struct LiveTVParsingTests {
    private static let playlist = """
    \u{FEFF}#EXTM3U x-tvg-url="https://guide.example/epg.xml.gz,https://guide.example/backup.xml"\r
    #EXTINF:-1 tvg-id="espn.us" tvg-logo="https://logo.example/espn.png" group-title="Sports;Trending",01 US: ESPN\r
    #EXTGRP:Ignored because group-title wins\r
    https://streams.example/u/p/200163456\r
    #EXTINF:-1 tvg-id="" tvg-name="News, Today" tvg-chno=7,News, Today\r
    #EXTGRP:News\r
    #EXTVLCOPT:http-user-agent=Custom/1.0\r
    #EXTVLCOPT:http-referrer=https://ref.example/\r
    https://streams.example/news.m3u8\r
    #EXTINF:-1,Piped\r
    https://streams.example/piped.ts|User-Agent=Kodi%2F21&Referer=https://kodi.example\r
    # a comment\r
    not a url\r
    """

    @Test func readsAttributesGroupsAndGuideAddresses() throws {
        let parsed = try M3UPlaylist.parse(Self.playlist)
        #expect(parsed.guideURLs.map(\.absoluteString) == ["https://guide.example/epg.xml.gz", "https://guide.example/backup.xml"])
        #expect(parsed.entries.count == 3)
        let espn = parsed.entries[0]
        #expect(espn.title == "01 US: ESPN")
        #expect(espn.tvgID == "espn.us")
        #expect(espn.logo?.absoluteString == "https://logo.example/espn.png")
        #expect(espn.groups == ["Sports", "Trending"])
        #expect(espn.url.absoluteString == "https://streams.example/u/p/200163456")
        let news = parsed.entries[1]
        #expect(news.title == "News, Today")
        #expect(news.tvgID == nil)
        #expect(news.number == "7")
        #expect(news.groups == ["News"])
        #expect(news.userAgent == "Custom/1.0")
        #expect(news.referrer == "https://ref.example/")
        let piped = parsed.entries[2]
        #expect(piped.url.absoluteString == "https://streams.example/piped.ts")
        #expect(piped.userAgent == "Kodi/21")
        #expect(piped.referrer == "https://kodi.example")
        #expect(piped.groups.isEmpty)
    }

    @Test func refusesTextThatIsNoPlaylist() {
        #expect(throws: M3UPlaylist.ParseError.notAPlaylist) { try M3UPlaylist.parse("<html>Not found</html>") }
        #expect(throws: M3UPlaylist.ParseError.empty) { try M3UPlaylist.parse("#EXTM3U\n") }
    }

    @Test func acceptsAPlaylistWithoutItsHeader() throws {
        let parsed = try M3UPlaylist.parse("#EXTINF:-1,One\nhttp://a.example/1\n")
        #expect(parsed.entries.map(\.title) == ["One"])
    }

    @Test func playlistChannelIdsHideTheirAddresses() throws {
        let playlist = LivePlaylist(id: "P", name: "Mine", address: URL(string: "https://provider.example/get.php?u=me&p=secret")!)
        let channels = PlaylistChannelSource.channels(of: playlist, in: try M3UPlaylist.parse(Self.playlist))
        #expect(channels.count == 3)
        for channel in channels {
            #expect(channel.id.hasPrefix("pl.P."))
            #expect(!channel.id.contains("streams.example"))
            #expect(channel.source == playlist.sourceID)
        }
        #expect(channels[0].guideKey == "espn.us")
        #expect(channels[1].guideKey == "News, Today")
        #expect(PlaylistChannelSource.channels(of: playlist, in: try M3UPlaylist.parse(Self.playlist)).map(\.id) == channels.map(\.id))
    }

    @Test func namesMatchAcrossCountryPrefixesAndQualityMarks() {
        #expect(PlaylistChannelSource.normalize("01 US: ESPN") == "espn")
        #expect(PlaylistChannelSource.normalize("UK: SKY SPORTS F1 FHD") == "sky sports f1")
        #expect(PlaylistChannelSource.normalize("Sky Sports F1 HD") == "sky sports f1")
    }

    private static let guide = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE tv SYSTEM "xmltv.dtd">
    <tv generator-info-name="test">
      <!-- channels -->
      <channel id="espn.us"><display-name>ESPN</display-name><display-name>ESPN HD</display-name><icon src="https://logo.example/e.png"/></channel>
      <channel id="other"><display-name lang="en">Sky Sports F1</display-name></channel>
      <programme start="20261122100000 +0000" stop="20261122110000 +0000" channel="espn.us">
        <title lang="en">SportsCenter &amp; More</title>
        <sub-title>Morning &#x26; Night</sub-title>
        <desc><![CDATA[Highlights <b>and</b> news]]></desc>
        <category>Sports</category><category>News</category>
        <episode-num system="xmltv_ns">1.4.0/1</episode-num>
        <icon src="https://img.example/sc.jpg" />
        <rating system="VCHIP"><value>TV-PG</value></rating>
        <new />
      </programme>
      <programme start="20261122120000 +0100" stop="20261122130000 +0100" channel="espn.us"><title>Noon in Paris</title><episode-num system="onscreen">S03E07</episode-num><live/></programme>
      <programme start="20261123100000 +0000" stop="20261123110000 +0000" channel="espn.us"><title>Tomorrow</title></programme>
      <programme start="20261122100000 -0500" channel="other"><title>No Stop</title></programme>
      <programme start="20261122100000 +0000" stop="20261122110000 +0000" channel="unwanted"><title>Skip</title></programme>
    </tv>
    """

    @Test func readsChannelsAndProgrammesWithTheirDetails() throws {
        let window = DateInterval(start: date("2026-11-22T00:00:00Z"), end: date("2026-11-23T00:00:00Z"))
        let parsed = try XMLTVGuide.parse(Data(Self.guide.utf8), window: window, channelIDs: ["espn.us", "other"])
        #expect(parsed.channels["espn.us"]?.names == ["ESPN", "ESPN HD"])
        #expect(parsed.channels["espn.us"]?.icon?.absoluteString == "https://logo.example/e.png")
        let espn = try #require(parsed.programmes["espn.us"])
        #expect(espn.map(\.title) == ["SportsCenter & More", "Noon in Paris"])
        let first = espn[0]
        #expect(first.subtitle == "Morning & Night")
        #expect(first.summary == "Highlights <b>and</b> news")
        #expect(first.categories == ["Sports", "News"])
        #expect(first.season == 2)
        #expect(first.episode == 5)
        #expect(first.icon?.absoluteString == "https://img.example/sc.jpg")
        #expect(first.rating == "TV-PG")
        #expect(first.isNew)
        #expect(first.start == date("2026-11-22T10:00:00Z"))
        #expect(espn[1].start == date("2026-11-22T11:00:00Z"))
        #expect(espn[1].season == 3 && espn[1].episode == 7)
        #expect(espn[1].isLive)
        let noStop = try #require(parsed.programmes["other"]?.first)
        #expect(noStop.start == date("2026-11-22T15:00:00Z"))
        #expect(noStop.stop == date("2026-11-22T15:30:00Z"))
        #expect(parsed.programmes["unwanted"] == nil)
    }

    @Test func readsAGzippedGuide() throws {
        let packed = try #require(Data(base64Encoded: "H4sIAAAAAAAC/1WPSwvCMBCE/0rIwYv0kR5EcJvixaMnxfPSLm0gL5JY9d/bYil1DssyH7vDQPM2mo0UonK25iIvOSPbuk7Zvub32yU78kZCGiW0A1pLmqmu5pg/I5fQqeg1fjKLhuRZ+wGh+POgWK4k+OD6gMYQiwlDqnlVVgchqkqUs9h+nnyCzm+Y2LLl1xqfVNIkr/SKbIfGn9iDMA0UoPgRKNbQaZ86fAF7vnV97gAAAA=="))
        let parsed = try XMLTVGuide.parse(packed)
        #expect(parsed.programmes["a.us"]?.first?.title == "News & Weather")
        #expect(parsed.channels["a.us"]?.names == ["Alpha"])
    }

    @Test func readsXMLTVTimes() {
        #expect(XMLTVGuide.date("20261122103000 +0000") == date("2026-11-22T10:30:00Z"))
        #expect(XMLTVGuide.date("20261122103000 +0530") == date("2026-11-22T05:00:00Z"))
        #expect(XMLTVGuide.date("20261122103000") == date("2026-11-22T10:30:00Z"))
        #expect(XMLTVGuide.date("202611221030") == date("2026-11-22T10:30:00Z"))
        #expect(XMLTVGuide.date("20240229000000 +0000") == date("2024-02-29T00:00:00Z"))
        #expect(XMLTVGuide.date("2026") == nil)
        #expect(XMLTVGuide.date("20261322000000") == nil)
    }

    @Test func guideMatchingFallsBackToNames() throws {
        let parsed = try XMLTVGuide.parse(Data(Self.guide.utf8))
        let index = PlaylistChannelSource.guideIndex(parsed)
        let source = LiveSourceID(kind: .playlist, key: "P")
        let byID = LiveChannel(id: "1", source: source, title: "Anything", guideKey: "ESPN.US", stream: .address(URL(string: "http://a")!, userAgent: nil, referrer: nil))
        let byName = LiveChannel(id: "2", source: source, title: "UK: SKY SPORTS F1 FHD", guideKey: nil, stream: .address(URL(string: "http://b")!, userAgent: nil, referrer: nil))
        let none = LiveChannel(id: "3", source: source, title: "Unknown", guideKey: "zzz", stream: .address(URL(string: "http://c")!, userAgent: nil, referrer: nil))
        #expect(PlaylistChannelSource.match(byID, in: parsed, index: index) == "espn.us")
        #expect(PlaylistChannelSource.match(byName, in: parsed, index: index) == "other")
        #expect(PlaylistChannelSource.match(none, in: parsed, index: index) == nil)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}

@Suite("Gzip")
struct GunzipTests {
    private let expected = Data((0..<400).map { "line \($0) of the guide\n" }.joined().utf8)

    @Test func unpacksDynamicHuffmanBlocks() throws {
        let packed = try #require(Data(base64Encoded: "H4sIAAAAAAAC/3XZS25lRRRE0T6j8BBeRNzvfCigpBJ0YP6ILlrVzZa3bN9cec6P739++/p8/fXb199/fPv6/Z/vv3775cd/Z8FZcTacHTg7cXbh7MbZg7NXPzNDVBKlRC1RTFQT5UQ9UVBUVBWVvxsVVUVVUVVUFVVFVVFVNBVNReOfm4qmoqloKpqKpqKp6FDRoaJDRQf/g1R0qOhQ0aGiQ0WHik4VnSo6VXSq6ORHQUWnik4VnSo6VXSp6FLRpaJLRZeKLn7nVHSp6FLRpaJbRbeKbhXdKrpVdKvo5qdbRbeKbhU9KnpU9KjoUdGjokdFj4oe3kYqelT0quhV0auiV0Wvil4VvSp6VfTygvUNyyv2wzv2w0v2w1v2w2v2w3v2w4v2w5v2w6v2w7af8IFtBoQFYULYEEaEFWFG0BEhJFLbiG20RIiJUBMhJ0JPhKAIRRGSIjRFZvixjawIXRHCIpRFSIvQFiEuQl2EvMhh1bKNwgiJERojREaojJAZoTNCaITSyGmys43YCLURciP0RgiOUBwhOUJzhOjI5fcI2+iOEB6hPEJ6hPYI8RHqI+RH6I/cfmyxjQQJDRIiJFRIyJDQISFEQomEFMnjlyTbqJGQI6FHQpCEIglJEpokREmokrx+JvudzIcyXVK6pHRJ6ZLSJaVLSpeULild0ngIwDa6pHRJ6ZLSJaVLSpeULqnnGx5w/GTCwTbPODzk8JTDYw7POTzooEtKl5Qu6Ty+YRtdUrqkdEnpktIlpUtKl5QuKV3Sw7MpttElpUtKl5QuKV1SuqR0SemS0iU9PXhjG11SuqR0SemS0iWlS0qXlC4pXdLLU0W20SWlS0qXlC4pXVK6pHRJ6ZLSJb09MmUbXVK6pHRJ6ZLSJaVLSpeULild0sfzYLbRJaVLSpeULildUrqkdEnpktIlfT3s9rSb4266ZHTJ6JLRJaNLRpeMLhldMrpk8SifbXTJ6JLRJaNLRpeMLhldMrpkdMnqPQXb6JLRJaNLRpeMLhldMm9gvILxDuYnSxi2eQ3jPYwXMd7EeBVDl4wuGV0yumSHN0xso0tGl4wuGV0yumR0yeiS0SWjS3Z6fcY2umR0yeiS0SWjS0aXjC4ZXTK6ZJd3g2yjS0aXjC4ZXTK6ZHTJ6JLRJaNLdnvxyTa6ZHTJ6JLRJaNLRpeMLhldMrpkj7e6bKNLRpeMLhldMrpkdMnoktElo0v2emX9v7Z/Afy4PrLyIQAA"))
        #expect(try Gunzip.unpack(packed) == expected)
    }

    @Test func unpacksStoredBlocks() throws {
        let packed = try #require(Data(base64Encoded: "H4sIAAAAAAAE/wEsAdP+bGluZSAwIG9mIHRoZSBndWlkZQpsaW5lIDEgb2YgdGhlIGd1aWRlCmxpbmUgMiBvZiB0aGUgZ3VpZGUKbGluZSAzIG9mIHRoZSBndWlkZQpsaW5lIDQgb2YgdGhlIGd1aWRlCmxpbmUgNSBvZiB0aGUgZ3VpZGUKbGluZSA2IG9mIHRoZSBndWlkZQpsaW5lIDcgb2YgdGhlIGd1aWRlCmxpbmUgOCBvZiB0aGUgZ3VpZGUKbGluZSA5IG9mIHRoZSBndWlkZQpsaW5lIDEwIG9mIHRoZSBndWlkZQpsaW5lIDExIG9mIHRoZSBndWlkZQpsaW5lIDEyIG9mIHRoZSBndWlkZQpsaW5lIDEzIG9mIHRoZSBndWlkZQpsaW5lIDE0IG9mIHRoZSBnHV/ndCwBAAA="))
        #expect(try Gunzip.unpack(packed) == expected.prefix(300))
    }

    @Test func inflatesFixedHuffmanBlocks() throws {
        let packed = try #require(Data(base64Encoded: "S0xKToQhhYzUnJx8FLI8vygnBQA="))
        #expect(String(decoding: try Gunzip.inflate(packed), as: UTF8.self) == "abcabcabcabc hello hello hello world")
    }

    @Test func refusesTruncatedAndOversizedData() throws {
        let packed = try #require(Data(base64Encoded: "H4sIAAAAAAAC/3XZS25lRRRE0T6j8BBeRNzvfCigpBJ0YP6ILlrVzZa3bN9cec6P739++/p8/fXb199/fPv6/Z/vv3775cd/Z8FZcTacHTg7cXbh7MbZg7NXPzNDVBKlRC1RTFQT5UQ9UVBUVBWVvxsVVUVVUVVUFVVFVVFVNBVNReOfm4qmoqloKpqKpqKp6FDRoaJDRQf/g1R0qOhQ0aGiQ0WHik4VnSo6VXSq6ORHQUWnik4VnSo6VXSp6FLRpaJLRZeKLn7nVHSp6FLRpaJbRbeKbhXdKrpVdKvo5qdbRbeKbhU9KnpU9KjoUdGjokdFj4oe3kYqelT0quhV0auiV0Wvil4VvSp6VfTygvUNyyv2wzv2w0v2w1v2w2v2w3v2w4v2w5v2w6v2w7af8IFtBoQFYULYEEaEFWFG0BEhJFLbiG20RIiJUBMhJ0JPhKAIRRGSIjRFZvixjawIXRHCIpRFSIvQFiEuQl2EvMhh1bKNwgiJERojREaojJAZoTNCaITSyGmys43YCLURciP0RgiOUBwhOUJzhOjI5fcI2+iOEB6hPEJ6hPYI8RHqI+RH6I/cfmyxjQQJDRIiJFRIyJDQISFEQomEFMnjlyTbqJGQI6FHQpCEIglJEpokREmokrx+JvudzIcyXVK6pHRJ6ZLSJaVLSpeULild0ngIwDa6pHRJ6ZLSJaVLSpeULqnnGx5w/GTCwTbPODzk8JTDYw7POTzooEtKl5Qu6Ty+YRtdUrqkdEnpktIlpUtKl5QuKV3Sw7MpttElpUtKl5QuKV1SuqR0SemS0iU9PXhjG11SuqR0SemS0iWlS0qXlC4pXdLLU0W20SWlS0qXlC4pXVK6pHRJ6ZLSJb09MmUbXVK6pHRJ6ZLSJaVLSpeULild0sfzYLbRJaVLSpeULildUrqkdEnpktIlfT3s9rSb4266ZHTJ6JLRJaNLRpeMLhldMrpk8SifbXTJ6JLRJaNLRpeMLhldMrpkdMnqPQXb6JLRJaNLRpeMLhldMm9gvILxDuYnSxi2eQ3jPYwXMd7EeBVDl4wuGV0yumSHN0xso0tGl4wuGV0yumR0yeiS0SWjS3Z6fcY2umR0yeiS0SWjS0aXjC4ZXTK6ZJd3g2yjS0aXjC4ZXTK6ZHTJ6JLRJaNLdnvxyTa6ZHTJ6JLRJaNLRpeMLhldMrpkj7e6bKNLRpeMLhldMrpkdMnoktElo0v2emX9v7Z/Afy4PrLyIQAA"))
        #expect(throws: Gunzip.Failure.tooLarge) { try Gunzip.unpack(packed, limit: 100) }
        #expect(throws: (any Error).self) { try Gunzip.unpack(packed.prefix(packed.count / 2)) }
        #expect(!Gunzip.isGzip(Data("<tv/>".utf8)))
    }
}
