import Foundation
import Testing

@testable import CrucibleCore

/// Builds a small MPEG transport stream: a PAT, a PMT naming an H.264 video stream and an AAC audio stream, and one PES
/// packet per frame with its timestamp, an IDR picture every `gop` frames.
private struct TransportStreamMaker {
    static let videoPID = 0x100
    static let audioPID = 0x101
    static let pmtPID = 0x1000
    var counters: [Int: UInt8] = [:]
    var randomAccessFlag = true

    mutating func stream(frames: Int, fps: Double = 30, gop: Int = 30, startPTS: Int64 = 900_000) -> Data {
        var data = Data()
        for frame in 0..<frames {
            if frame % 15 == 0 {
                data += pat()
                data += pmt()
            }
            let pts = startPTS + Int64(Double(frame) * 90_000 / fps)
            data += pes(pid: Self.videoPID, pts: pts, keyframe: frame % gop == 0, video: true)
            if frame % 2 == 0 { data += pes(pid: Self.audioPID, pts: pts, keyframe: false, video: false) }
        }
        return data
    }

    private mutating func packet(pid: Int, unitStart: Bool, randomAccess: Bool = false, payload: [UInt8]) -> Data {
        let counter = counters[pid, default: 0]
        counters[pid] = (counter + 1) & 0x0F
        var bytes: [UInt8] = [0x47, UInt8((unitStart ? 0x40 : 0) | (pid >> 8 & 0x1F)), UInt8(pid & 0xFF)]
        let body = Array(payload.prefix(randomAccess ? 182 : 184))
        if body.count == 184 {
            bytes.append(0x10 | counter)
        } else {
            let length = 183 - body.count
            bytes.append(0x30 | counter)
            bytes.append(UInt8(length))
            if length > 0 { bytes += [randomAccess ? 0x40 : 0x00] + [UInt8](repeating: 0xFF, count: length - 1) }
        }
        bytes += body
        return Data(bytes)
    }

    private mutating func pat() -> Data {
        let section: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, UInt8(0xE0 | Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF), 0, 0, 0, 0]
        return packet(pid: 0, unitStart: true, payload: [0x00] + section)
    }

    private mutating func pmt() -> Data {
        var section: [UInt8] = [0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00, UInt8(0xE0 | Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        section += [0x1B, UInt8(0xE0 | Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        section += [0x0F, UInt8(0xE0 | Self.audioPID >> 8), UInt8(Self.audioPID & 0xFF), 0xF0, 0x00]
        section += [0, 0, 0, 0]
        return packet(pid: Self.pmtPID, unitStart: true, payload: [0x00] + section)
    }

    private mutating func pes(pid: Int, pts: Int64, keyframe: Bool, video: Bool) -> Data {
        let ptsBytes: [UInt8] = [
            UInt8(0x21 | (pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF), UInt8(0x01 | (pts >> 14) & 0xFE), UInt8((pts >> 7) & 0xFF), UInt8(0x01 | (pts << 1) & 0xFE),
        ]
        var payload: [UInt8] = [0x00, 0x00, 0x01, video ? 0xE0 : 0xC0, 0x00, 0x00, 0x80, 0x80, 0x05] + ptsBytes
        if video {
            payload += [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0]
            payload += keyframe ? [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E, 0x00, 0x00, 0x01, 0x65, 0x88] : [0x00, 0x00, 0x00, 0x01, 0x41, 0x9A]
        } else {
            payload += [0xFF, 0xF1, 0x50, 0x80, 0x01, 0x7F, 0xFC]
        }
        var data = packet(pid: pid, unitStart: true, randomAccess: keyframe && randomAccessFlag, payload: payload)
        if video { data += packet(pid: pid, unitStart: false, payload: [UInt8](repeating: 0xAB, count: 184)) }
        return data
    }
}

@Suite("Transport stream to HLS")
struct TransportStreamSegmenterTests {
    @Test func cutsOnKeyframesWithTablesInFront() throws {
        var maker = TransportStreamMaker()
        let stream = maker.stream(frames: 30 * 7)
        var segmenter = TransportStreamSegmenter(targetDuration: 2)
        var segments: [TransportStreamSegmenter.Segment] = []
        var offset = 0
        let chunk = 1000
        while offset < stream.count {
            segments += segmenter.append(stream.subdata(in: offset..<min(offset + chunk, stream.count)))
            offset += chunk
        }
        if let last = segmenter.flush() { segments.append(last) }
        #expect(segmenter.hasVideo)
        #expect(segments.map(\.sequence) == Array(0..<segments.count))
        #expect(segments.count == 4)
        for segment in segments.dropLast() { #expect(abs(segment.duration - 2) < 0.01) }
        for segment in segments {
            #expect(segment.data.count % 188 == 0)
            let first = [UInt8](segment.data.prefix(188 * 3))
            #expect(first[0] == 0x47 && (Int(first[1] & 0x1F) << 8 | Int(first[2])) == 0)
            #expect((Int(first[189] & 0x1F) << 8 | Int(first[190])) == TransportStreamMaker.pmtPID)
            #expect((Int(first[377] & 0x1F) << 8 | Int(first[378])) == TransportStreamMaker.videoPID)
            #expect(first[377] & 0x40 != 0)
        }
    }

    @Test func findsKeyframesWithoutTheRandomAccessFlag() {
        var maker = TransportStreamMaker()
        maker.randomAccessFlag = false
        var segmenter = TransportStreamSegmenter(targetDuration: 2)
        let segments = segmenter.append(maker.stream(frames: 30 * 5))
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { abs($0.duration - 2) < 0.01 })
    }

    @Test func resynchronisesAfterGarbage() {
        var maker = TransportStreamMaker()
        var segmenter = TransportStreamSegmenter(targetDuration: 2)
        var data = Data([0x00, 0x47, 0x12, 0x99])
        data += maker.stream(frames: 30 * 3)
        data += Data([0x47, 0x00, 0x00])
        data += maker.stream(frames: 30 * 3, startPTS: 900_000 + 90_000 * 3)
        let segments = segmenter.append(data)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.data.count % 188 == 0 })
    }

    @Test func survivesTheTimestampWrap() {
        var maker = TransportStreamMaker()
        var segmenter = TransportStreamSegmenter(targetDuration: 2)
        let segments = segmenter.append(maker.stream(frames: 30 * 5, startPTS: (1 << 33) - 90_000))
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { abs($0.duration - 2) < 0.01 })
    }

    @Test func windowListsTheLatestSegments() {
        var window = LiveHLSWindow(capacity: 3)
        for sequence in 0..<5 { window.add(TransportStreamSegmenter.Segment(sequence: sequence, data: Data([0]), duration: sequence == 4 ? 2.4 : 2)) }
        #expect(window.segments.map(\.sequence) == [2, 3, 4])
        #expect(window.segment(1) == nil)
        #expect(window.segment(3) != nil)
        let text = window.playlist
        #expect(text.contains("#EXT-X-TARGETDURATION:3"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:2"))
        #expect(text.contains("#EXTINF:2.400,\nsegment-4.ts"))
        #expect(!text.contains("ENDLIST"))
    }

    @Test func playlistAddressesThatNameHLSPlayDirectly() {
        #expect(LivePlayback.format(of: URL(string: "https://a.example/live/1.m3u8?token=x")!) == .hls)
        #expect(LivePlayback.format(of: URL(string: "https://a.example/get?output=hls&id=3")!) == .hls)
        #expect(LivePlayback.format(of: URL(string: "https://soursignal.example/123/key/200163456")!) == .transportStream)
        #expect(LivePlayback.format(of: URL(string: "https://a.example/1.ts")!) == .transportStream)
    }
}

@Suite("Plex live TV")
struct PlexLiveTVTests {
    private static let channelsJSON = """
    {"MediaContainer":{"size":2,"Channel":[
      {"gridKey":"g1","id":"c1","title":"FIFA+","thumb":"https://provider-static.plex.tv/logo.png","isHd":false,"hidden":false,"genreRatingKeys":["genre_s"],
       "summary":"Football","Media":[{"drm":false,"protocol":"hls","Part":[{"key":"/library/parts/c1.m3u8"}]}]},
      {"gridKey":"g2","id":"c2","title":"Locked","isHd":"1","hidden":"0","Media":[{"drm":true,"Part":[{"key":"/library/parts/c2.m3u8"}]}]}
    ]}}
    """

    private static let gridJSON = """
    {"MediaContainer":{"size":2,"Metadata":[
      {"guid":"plex://episode/1","type":"episode","title":"Episode 1","grandparentTitle":"Brazil v Belgium","hasGenericTitle":true,"index":1,"parentIndex":1,
       "summary":"Replay","contentRating":"TV-G","Genre":[{"tag":"Sports"}],"Image":[{"type":"snapshot","url":"https://img.example/s.jpg"}],
       "Media":[{"beginsAt":1795300283,"endsAt":1795307210,"onAir":true,"premiere":false}]},
      {"guid":"plex://episode/2","type":"episode","title":"Pilot","grandparentTitle":"Show","index":"3","parentIndex":"2","thumb":"/library/metadata/2/thumb",
       "Media":[{"beginsAt":"1795307210","endsAt":"1795309010"}]},
      {"type":"movie","title":"No Times","Media":[{"onAir":false}]},
      {"type":"movie","title":"Twice","Media":[{"beginsAt":1795309010,"endsAt":1795312610},{"beginsAt":1795330000,"endsAt":1795333600}]}
    ]}}
    """

    @Test func decodesChannelsAndAirings() throws {
        let channels = try JSONDecoder().decode(PlexLiveContainer<PlexLiveChannelsBody>.self, from: Data(Self.channelsJSON.utf8)).MediaContainer.Channel ?? []
        #expect(channels.count == 2)
        #expect(channels[0].gridKey == "g1")
        #expect(channels[1].isHd)
        #expect(!channels[1].hidden)
        #expect(channels[1].Media?.first?.drm == true)
        let airings = try JSONDecoder().decode(PlexLiveContainer<PlexLiveGridBody>.self, from: Data(Self.gridJSON.utf8)).MediaContainer.Metadata ?? []
        let base = URL(string: "https://epg.provider.plex.tv")
        let programs = airings.flatMap { $0.programs(channelID: "plex.c1", imageBase: base) }
        #expect(programs.count == 4)
        #expect(programs.filter { $0.title == "Twice" }.map(\.start) == [Date(timeIntervalSince1970: 1795309010), Date(timeIntervalSince1970: 1795330000)])
        #expect(Set(programs.map(\.id)).count == 4)
        let replay = programs[0]
        #expect(replay.title == "Brazil v Belgium")
        #expect(replay.episodeTitle == nil)
        #expect(replay.episodeCode == nil)
        #expect(replay.isLive)
        #expect(replay.genres == ["Sports"])
        #expect(replay.image?.absoluteString == "https://img.example/s.jpg")
        #expect(replay.record == LiveRecordHint(guid: "plex://episode/1", isEpisode: true))
        #expect(replay.start == Date(timeIntervalSince1970: 1795300283))
        let pilot = programs[1]
        #expect(pilot.title == "Show")
        #expect(pilot.episodeTitle == "Pilot")
        #expect(pilot.season == 2 && pilot.episode == 3)
        #expect(pilot.image?.absoluteString == "https://epg.provider.plex.tv/library/metadata/2/thumb")
    }

    @Test func gridDatesCoverTheWindowInUTC() {
        let start = Date(timeIntervalSince1970: 1795300283)
        let dates = PlexLiveLenient.gridDates(covering: DateInterval(start: start, duration: 30 * 3600))
        #expect(dates.count == 3)
        #expect(dates.first == "2026-11-21")
        #expect(dates.last == "2026-11-23")
    }

    @Test func freeChannelAddressesCarryThePlayerFields() throws {
        let url = try #require(PlexFreeChannelSource.streamURL(partKey: "/library/parts/c1.m3u8", token: "TOKEN"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/library/parts/c1.m3u8")
        #expect(items.first { $0.name == "X-Plex-Token" }?.value == "TOKEN")
        #expect(items.contains { $0.name == "X-Plex-Client-Identifier" })
    }

    @Test func decodesDVRsAndSkipsTuners() throws {
        let json = """
        {"MediaContainer":{"size":2,"Dvr":[
          {"key":"28","language":"eng","lineup":"lineup://x","uuid":"811e","lineupTitle":"Antenna","epgIdentifier":"tv.plex.providers.epg.cloud:28",
           "Device":[{"make":"Silicondust","model":"HDHomeRun","ChannelMapping":[{"channelKey":"k1","enabled":"1"},{"channelKey":"k2","enabled":"0"}]}]},
          {"key":"17","uuid":"device://tv.plex.grabbers.hdhomerun/1053C0CA","model":"HDHomeRun EXTEND"},
          {"key":5,"uuid":"abc"}
        ]}}
        """
        let dvrs = try JSONDecoder().decode(PlexLiveContainer<PlexDVRListBody>.self, from: Data(json.utf8)).MediaContainer.Dvr?.compactMap(\.dvr) ?? []
        #expect(dvrs.count == 2)
        #expect(dvrs[0] == PlexDVR(key: "28", title: "Antenna", epgIdentifier: "tv.plex.providers.epg.cloud:28", enabledChannels: ["k1"]))
        #expect(dvrs[1].epgIdentifier == "tv.plex.providers.epg.cloud:5")
        #expect(dvrs[1].enabledChannels == nil)
    }

    @Test func buildsTheRecordingQueryFromTheTemplate() throws {
        let json = """
        {"MediaContainer":{"size":1,"SubscriptionTemplate":[{"MediaSubscription":[
          {"parameters":"hints%5Bguid%5D=plex%3A%2F%2Fepisode%2F5&hints%5BratingKey%5D=plex%253A%252F%252Fepisode%252F5&params%5BmediaProviderID%5D=13","selected":true,"type":4,
           "targetLibrarySectionID":2,"title":"This Episode","Setting":[
             {"id":"minVideoQuality","label":"Resolution","type":"int","default":"0","value":"0","hidden":false,"advanced":true,"enumValues":"0:Prefer HD|720:HD only"},
             {"id":"recordPartials","label":"Allow partial airings","type":"bool","value":"true","hidden":false,"advanced":true}]},
          {"parameters":"hints%5Bguid%5D=plex%3A%2F%2Fshow%2F9","type":2,"targetLibrarySectionID":"2","title":"All Episodes",
           "Setting":[{"id":"onlyNewAirings","label":"Airings","type":"int","value":1,"enumValues":"0:New and Repeat Airings|1:New Airings Only"}]}
        ]}]}}
        """
        let body = try JSONDecoder().decode(PlexLiveContainer<LiveRecordings.TemplateBody>.self, from: Data(json.utf8))
        let subscriptions = (body.MediaContainer.SubscriptionTemplate ?? []).flatMap { $0.MediaSubscription ?? [] }
        #expect(subscriptions.count == 2)
        let settings = subscriptions[0].Setting?.map(\.setting) ?? []
        #expect(settings[0].choices.map(\.title) == ["Prefer HD", "HD only"])
        #expect(settings[0].currentChoice?.title == "Prefer HD")
        #expect(settings[1].isBool && settings[1].value == "true")
        #expect(subscriptions[1].Setting?.first?.setting.value == "1")
        let option = RecordingOption(id: "0", title: "This Episode", type: 4, parameters: subscriptions[0].parameters ?? "", targetLibrarySectionID: 2,
                                     targetSectionLocationID: nil, librarySectionTitle: nil, isSelected: true, settings: settings)
        let query = LiveRecordings.query(for: option, values: ["minVideoQuality": "720"])
        let pairs = query.map { "\($0.name)=\($0.value ?? "")" }
        #expect(pairs.contains("hints[guid]=plex://episode/5"))
        #expect(pairs.contains("hints[ratingKey]=plex%3A%2F%2Fepisode%2F5"))
        #expect(pairs.contains("params[mediaProviderID]=13"))
        #expect(pairs.contains("targetLibrarySectionID=2"))
        #expect(pairs.contains("type=4"))
        #expect(pairs.contains("prefs[minVideoQuality]=720"))
        #expect(pairs.contains("prefs[recordPartials]=true"))
        #expect(!option.isSeries)
    }

    @Test func decodesScheduledRecordings() throws {
        let json = """
        {"MediaContainer":{"size":1,"MediaGrabOperation":[{"mediaSubscriptionID":1,"status":"scheduled","Metadata":{"type":"episode","title":"Miracle on Dead Street",
         "grandparentTitle":"Fresh Off the Boat","index":5,"parentIndex":2,"guid":"plex://episode/3",
         "Media":[{"beginsAt":1466060400,"endsAt":"1466062200","channelIdentifier":"004","channelVcn":"4.1","channelTitle":"ABC"}]}}]}}
        """
        let body = try JSONDecoder().decode(PlexLiveContainer<LiveRecordings.ScheduledBody>.self, from: Data(json.utf8))
        let recording = try #require(body.MediaContainer.MediaGrabOperation?.first?.recording(base: URL(string: "http://server:32400")!))
        #expect(recording.status == .scheduled)
        #expect(recording.title == "Fresh Off the Boat")
        #expect(recording.episodeTitle == "Miracle on Dead Street")
        #expect(recording.channel == "4.1 ABC")
        #expect(recording.ruleKey == "1")
        #expect(recording.start == Date(timeIntervalSince1970: 1466060400))
    }

    @Test func tuneSessionsPlayThroughTheTranscoder() throws {
        let url = try #require(LivePlayback.transcodeURL(base: URL(string: "http://192.168.1.2:32400")!, token: "T", path: "/livetv/sessions/abc", session: "S"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/video/:/transcode/universal/start.m3u8")
        #expect(items.first { $0.name == "path" }?.value == "/livetv/sessions/abc")
        #expect(items.first { $0.name == "directStream" }?.value == "1")
        #expect(items.first { $0.name == "session" }?.value == "S")
    }
}

@Suite("Live TV guide")
struct LiveGuideTests {
    private func program(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> LiveProgram {
        LiveProgram(id: id, channelID: "c", title: id, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    @Test func findsWhatIsOnAndWhatIsNext() {
        let list = [program("a", 0, 100), program("b", 100, 200), program("c", 250, 300)]
        let mid = LiveGuideMath.nowAndNext(list, at: Date(timeIntervalSince1970: 150))
        #expect(mid.now?.id == "b" && mid.next?.id == "c")
        let gap = LiveGuideMath.nowAndNext(list, at: Date(timeIntervalSince1970: 220))
        #expect(gap.now == nil && gap.next?.id == "c")
        let after = LiveGuideMath.nowAndNext(list, at: Date(timeIntervalSince1970: 400))
        #expect(after.now == nil && after.next == nil)
    }

    @Test func normalisesOverlapsAndDuplicates() {
        let list = [program("b", 100, 200), program("a", 0, 120), program("a", 0, 120), program("inside", 30, 60), program("c", 400, 500)]
        let result = LiveGuideMath.normalized(list, in: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 300)))
        #expect(result.map(\.id) == ["a", "b"])
        #expect(result[1].start == Date(timeIntervalSince1970: 120))
    }

    @Test func ordersChannelNumbersLikeARemote() {
        let numbers: [String?] = ["10", nil, "2", "5.2", "5.1", "", "5"]
        #expect(numbers.sorted(by: LiveGuideMath.numberOrder).map { $0 ?? "-" } == ["2", "5", "5.1", "5.2", "10", "-", ""].map { $0 })
    }

    @Test func placesAiringsInTheGrid() {
        let origin = Date(timeIntervalSince1970: 3600)
        let span = LiveGuideMath.span(of: program("a", 1800, 7200), origin: origin, pointsPerHour: 200)
        #expect(span.x == 0 && span.width == 200)
        let later = LiveGuideMath.span(of: program("b", 5400, 9000), origin: origin, pointsPerHour: 200)
        #expect(later.x == 100 && later.width == 200)
        #expect(LiveGuideMath.slotStart(Date(timeIntervalSince1970: 3600 + 1799)) == origin)
    }

    @Test func linksAddPlaylists() throws {
        let playlist = LivePlaylist(name: "My TV", address: URL(string: "https://provider.example/iptv.php/25/Key/@top")!,
                                    guideAddress: URL(string: "https://guide.example/epg.xml.gz?u=a&p=b")!, userAgent: "VLC/3")
        let url = try #require(LiveTVLink.url(adding: playlist))
        #expect(url.absoluteString.hasPrefix("crucible://livetv/add?"))
        guard case .add(let parsed)? = LiveTVLink(url: url) else {
            Issue.record("The link did not parse")
            return
        }
        #expect(parsed.address == playlist.address)
        #expect(parsed.guideAddress == playlist.guideAddress)
        #expect(parsed.name == "My TV")
        #expect(parsed.userAgent == "VLC/3")
        #expect(LiveTVLink(url: URL(string: "crucible://livetv")!) == .open)
        #expect(LiveTVLink(url: URL(string: "crucible://livetv/add?url=ftp://x")!) == nil)
        #expect(LiveTVLink(url: URL(string: "crucible://item/1")!) == nil)
        guard case .add(let bare)? = LiveTVLink(url: URL(string: "crucible://livetv/add?url=www.iptv.example/list.m3u")!) else {
            Issue.record("A bare host did not parse")
            return
        }
        #expect(bare.name == "iptv.example")
        #expect(bare.address.absoluteString == "http://www.iptv.example/list.m3u")
    }
}
