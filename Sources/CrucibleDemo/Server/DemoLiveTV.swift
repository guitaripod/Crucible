import Foundation

/// Live TV in the demo, so every part of it can be tried without a Plex account, a tuner or a playlist: Plex's free channels
/// (as Plex's live TV service answers), and an antenna tuner on the demo server with its guide, live viewing and recordings.
/// The channels, airings and logos are fictional and every channel shows the demo's clip.
actor DemoLiveTV {
    static let shared = DemoLiveTV()

    private static let dvrKey = "7"
    private static let epg = "tv.plex.providers.epg.cloud:7"
    private static let free: [(key: String, title: String, genre: String, summary: String)] = [
        ("ember-news", "Ember News", "news", "News around the clock from the harbour cities."),
        ("northern-lights", "Northern Lights", "explore", "Documentaries from the far north."),
        ("crucible-classics", "Crucible Classics", "movies", "Films from the archive, uncut."),
        ("cartographers", "The Cartographers", "explore", "Maps, journeys and the people who make them."),
        ("harbour-sports", "Harbour Sports", "sports", "Rowing, sailing and the harbour league."),
        ("kitchen-stories", "Kitchen Stories", "food", "Cooking from every coast."),
        ("night-shift", "Night Shift", "crime", "Detective series, back to back."),
        ("little-lanterns", "Little Lanterns", "kids", "Shows for the youngest viewers."),
    ]
    private static let genres: [(String, String)] = [("news", "News"), ("explore", "Explore"), ("movies", "Movies"), ("sports", "Sports"),
                                                     ("food", "Food & Home"), ("crime", "True Crime"), ("kids", "Kids & Family")]
    private static let antenna: [(vcn: String, call: String, title: String)] = [
        ("2.1", "KMRN", "Marren Public"), ("4.1", "KVLE", "Vale Four"), ("7.1", "WHAL", "Hale Seven"), ("9.1", "KSTO", "Sato Nine"),
    ]
    private static let shows = ["Harbour Lights", "The Long Crossing", "Ember & Ash", "North of Nowhere", "Saltwater", "The Quiet Coast", "Cartography",
                                "Night Ferry", "Lanterns", "The Keeper", "Tidewater", "Glasswork", "Driftwood Kitchen", "The Inspector Calls Again"]
    private static let episodes = ["Low Tide", "The Signal", "Fog Bank", "First Light", "The Map Room", "Undertow", "A Ship Called Hope", "Breakwater",
                                   "Lantern Night", "The Last Ferry", "Northbound", "Salt", "The Keeper's Log", "Harbour Master"]
    private static let synopses: [String: String] = [
        "Harbour Lights": "A harbour pilot and her estranged brother keep the port running through one hard winter.",
        "The Long Crossing": "Six strangers share a cabin on a ferry that never quite reaches the other side.",
        "Ember & Ash": "Two rival bakers inherit the same shop and refuse to share the oven.",
        "North of Nowhere": "A rookie constable takes the only post above the Arctic Circle, and the town takes him in.",
        "Saltwater": "A family of oyster farmers fights to keep their beds through a season of storms.",
        "The Quiet Coast": "Wildlife cameras follow seals, puffins and foxes along an empty shoreline.",
        "Cartography": "Mapmakers retrace the routes of the old surveys, one coastline at a time.",
        "Night Ferry": "A night-shift deckhand hears every secret aboard the last crossing of the day.",
        "Lanterns": "A lighthouse keeper's daughter solves small mysteries in a fishing village.",
        "The Keeper": "The last keeper of a remote light decides whether to leave the rock for good.",
        "Tidewater": "A river-delta town argues over the flood barrier that will change it for ever.",
        "Glasswork": "A glassblower's workshop takes on its most ambitious commission yet.",
        "Driftwood Kitchen": "A chef cooks only what the morning's catch and the tide line bring in.",
        "The Inspector Calls Again": "A retired inspector keeps being asked back for one last case.",
    ]

    private var subscriptions: [String: (guid: String, type: Int)] = [:]
    private var nextKey = 1

    /// Answers a Live TV request, or nil when the path is not Live TV's.
    func respond(_ parts: [String], _ request: DemoRequest, viaPlexTV: Bool, assets: DemoAssets) -> DemoResponse? {
        switch parts.first {
        case nil where viaPlexTV:
            return .json(Self.provider)
        case "lineups" where parts == ["lineups", "plex", "channels"]:
            return .container(["size": Self.free.count, "identifier": "tv.plex.provider.epg", "Channel": Self.freeChannels])
        case "grid":
            return grid(request)
        case Self.epg:
            if parts.dropFirst() == ["lineups", "dvr", "channels"] { return .container(["size": Self.antenna.count, "Channel": Self.antennaChannels]) }
            if parts.dropFirst() == ["grid"] { return grid(request) }
            return .notFound()
        case "livetv" where parts.count == 3 && parts[1] == "logo":
            return DemoFiles.respond(assets.image("livetv_logo_\(parts[2])"), contentType: "image/png", request: nil)
        case "livetv":
            return liveTV(Array(parts.dropFirst()), request)
        case "media":
            return media(Array(parts.dropFirst()), request)
        default:
            return nil
        }
    }

    private static var provider: [String: Any] {
        ["MediaProvider": ["identifier": "tv.plex.provider.epg", "title": "Live TV", "protocols": ["livetv"],
                           "Feature": [["type": "grid", "key": "/grid",
                                        "GridChannelFilter": genres.map { ["identifier": $0.0, "genreRatingKey": "genre_\($0.0)", "title": $0.1] }]]]]
    }

    private static var freeChannels: [[String: Any]] {
        free.map { channel in
            ["id": "free-\(channel.key)", "gridKey": "free-\(channel.key)", "title": channel.title, "thumb": "/livetv/logo/\(channel.key).png",
             "summary": channel.summary, "isHd": true, "hidden": false, "genreRatingKeys": ["genre_\(channel.genre)"],
             "Media": [["drm": false, "protocol": "hls", "Part": [["key": "/livetv/free/\(channel.key).m3u8"]]]]]
        }
    }

    private static var antennaChannels: [[String: Any]] {
        antenna.map { channel in
            ["id": "antenna-\(channel.vcn)", "gridKey": "antenna-\(channel.vcn)", "vcn": channel.vcn, "title": channel.title, "callSign": channel.call,
             "thumb": "/livetv/logo/\(slug(channel.vcn)).png", "isHd": "1"]
        }
    }

    private static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// A stable number for a channel and a moment, so the guide is the same each time it is asked.
    private static func stable(_ parts: String...) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % 1_000_000_007)
    }

    /// A day of airings on a channel: shows of half an hour to two hours.
    private static func airings(_ channel: String, from day: Int) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var start = day
        let now = Int(Date().timeIntervalSince1970)
        while start < day + 86400 {
            let seed = stable(channel, String(start))
            let length = [1800, 1800, 3600, 3600, 5400, 7200][seed % 6]
            let show = shows[seed % shows.count]
            let episode = episodes[(seed / 7) % episodes.count]
            let guid = "plex://episode/demo-\(slug(channel))-\(start)"
            result.append([
                "guid": guid, "ratingKey": guid, "type": "episode", "title": episode, "grandparentTitle": show,
                "parentIndex": 1 + seed % 4, "index": 1 + (seed / 13) % 12, "contentRating": "TV-PG",
                "summary": synopses[show] ?? show,
                "Genre": [["tag": "Drama"]],
                "Media": [["beginsAt": start, "endsAt": start + length, "onAir": start <= now && now < start + length, "premiere": seed % 9 == 0,
                           "channelIdentifier": channel, "channelTitle": channel]],
            ])
            start += length
        }
        return result
    }

    private func grid(_ request: DemoRequest) -> DemoResponse {
        guard let key = request.first("channelGridKey"), let date = request.first("date"), let day = Self.day(date) else {
            return .json(["Error": ["message": "Invalid value provided for date!"]], status: 400)
        }
        let rows = Self.airings(key, from: day)
        return .container(["size": rows.count, "Metadata": rows])
    }

    private static func day(_ date: String) -> Int? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components).map { Int($0.timeIntervalSince1970) }
    }

    private func liveTV(_ parts: [String], _ request: DemoRequest) -> DemoResponse {
        switch parts.first {
        case "free":
            let key = parts.last?.replacingOccurrences(of: ".m3u8", with: "") ?? "demo"
            return DemoResponse(status: 302, headers: ["Location": "/video/:/transcode/universal/start.m3u8?session=live-\(key)"])
        case "dvrs" where parts.count == 1:
            return .container(["size": 1, "Dvr": [["key": Self.dvrKey, "uuid": "demo-dvr", "lineupTitle": "Antenna", "epgIdentifier": Self.epg,
                                                    "Device": [["make": "Silicondust", "model": "HDHomeRun FLEX 4K",
                                                                "ChannelMapping": Self.antenna.map { ["channelKey": "antenna-\($0.vcn)", "enabled": "1"] }]]]]])
        case "dvrs" where parts.last == "tune":
            let session = UUID().uuidString
            return .container(["size": 1, "Metadata": [["key": "/livetv/sessions/\(session)", "live": true, "Media": [["uuid": session]]]]])
        default:
            return .notFound()
        }
    }

    private func media(_ parts: [String], _ request: DemoRequest) -> DemoResponse {
        switch (request.method, parts) {
        case ("GET", ["subscriptions", "template"]):
            return template(guid: request.first("guid") ?? "")
        case ("GET", ["subscriptions", "scheduled"]):
            return scheduled()
        case ("POST", ["subscriptions"]):
            let key = String(nextKey)
            nextKey += 1
            subscriptions[key] = (request.first("hints[guid]") ?? "", Int(request.first("type") ?? "4") ?? 4)
            return .container(["size": 1, "MediaSubscription": [["key": key, "type": subscriptions[key]?.type ?? 4, "title": subscriptions[key]?.guid ?? ""]]])
        case ("GET", ["subscriptions"]):
            let rules = subscriptions.sorted { $0.key < $1.key }.map { key, value in
                ["key": key, "type": value.type, "title": Self.airing(value.guid)?["grandparentTitle"] as? String ?? value.guid,
                 "librarySectionTitle": "TV Shows", "airingsType": "New Airings Only"] as [String: Any]
            }
            return .container(["size": rules.count, "MediaSubscription": rules])
        case ("DELETE", let path) where path.count == 2 && path[0] == "subscriptions":
            subscriptions[path[1]] = nil
            return .empty()
        case ("DELETE", let path) where path.count == 3 && path[0] == "grabbers":
            subscriptions[path[2].replacingOccurrences(of: "grab-", with: "")] = nil
            return .empty()
        default:
            return .notFound()
        }
    }

    private func template(guid: String) -> DemoResponse {
        let encoded = guid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? guid
        let parameters = "hints%5Bguid%5D=\(encoded)&hints%5Btype%5D=4&params%5BmediaProviderID%5D=13&params%5BlibraryType%5D=2"
        let settings: [[String: Any]] = [
            ["id": "minVideoQuality", "label": "Resolution", "type": "int", "default": "0", "value": "0", "hidden": false, "advanced": true,
             "enumValues": "0:Prefer HD|720:HD only"],
            ["id": "recordPartials", "label": "Allow partial airings", "type": "bool", "default": "true", "value": "true", "hidden": false, "advanced": true],
        ]
        let options: [[String: Any]] = [
            ["parameters": parameters, "selected": true, "type": 4, "targetLibrarySectionID": 2, "title": "This Episode", "librarySectionTitle": "TV Shows",
             "airingsType": "New Airings Only", "Setting": settings],
            ["parameters": parameters.replacingOccurrences(of: "hints%5Btype%5D=4", with: "hints%5Btype%5D=2"), "type": 2, "targetLibrarySectionID": 2,
             "title": "All Episodes", "librarySectionTitle": "TV Shows", "airingsType": "New Airings Only", "Setting": settings],
        ]
        return .container(["size": 1, "SubscriptionTemplate": [["MediaSubscription": options]]])
    }

    private static func airing(_ guid: String) -> [String: Any]? {
        let now = Int(Date().timeIntervalSince1970)
        let today = now - now % 86400
        for channel in antenna {
            for day in [today, today + 86400] {
                if let found = airings("antenna-\(channel.vcn)", from: day).first(where: { $0["guid"] as? String == guid }) { return found }
            }
        }
        return nil
    }

    private func scheduled() -> DemoResponse {
        let now = Int(Date().timeIntervalSince1970)
        let operations: [[String: Any]] = subscriptions.sorted { $0.key < $1.key }.compactMap { key, value in
            guard let airing = Self.airing(value.guid), let media = (airing["Media"] as? [[String: Any]])?.first,
                  let begins = media["beginsAt"] as? Int, let ends = media["endsAt"] as? Int else { return nil }
            let recording = begins <= now && now < ends
            return ["id": "grab-\(key)", "mediaSubscriptionID": key, "status": recording ? "inprogress" : "scheduled", "percent": recording ? 40 : 0,
                    "Metadata": airing]
        }
        return .container(["size": operations.count, "MediaGrabOperation": operations])
    }

    /// Forgets the recordings made in the demo, for a fresh start.
    func reset() {
        subscriptions = [:]
        nextKey = 1
    }
}
