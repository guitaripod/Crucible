import Foundation

/// An XMLTV programme guide: the channels it describes and their airings. Read with a small byte scanner rather than an XML
/// library, so a guide of tens of megabytes parses quickly on every platform and nothing but the fields the guide shows is
/// kept.
package struct XMLTVGuide: Sendable {
    package struct Channel: Sendable, Equatable {
        package var id: String
        package var names: [String] = []
        package var icon: URL?
    }

    package struct Programme: Sendable, Equatable {
        package var channel: String
        package var start: Date
        package var stop: Date
        package var title: String = ""
        package var subtitle: String?
        package var summary: String?
        package var categories: [String] = []
        package var icon: URL?
        package var season: Int?
        package var episode: Int?
        package var rating: String?
        package var isNew = false
        package var isPremiere = false
        package var isLive = false
    }

    package var channels: [String: Channel]
    /// Airings by channel id, in start order.
    package var programmes: [String: [Programme]]

    /// Reads `data` (plain or gzip), keeping only airings that overlap `window` and, when `channelIDs` is given, only those
    /// channels.
    package static func parse(_ data: Data, window: DateInterval? = nil, channelIDs: Set<String>? = nil) throws -> XMLTVGuide {
        let bytes = Gunzip.isGzip(data) ? try Gunzip.unpack(data) : data
        var scanner = XMLScanner(bytes: [UInt8](bytes))
        var channels: [String: Channel] = [:]
        var programmes: [String: [Programme]] = [:]
        var channel: Channel?
        var programme: Programme?
        var text: String?
        var episodeSystem: String?
        var inRating = false
        while let event = scanner.next() {
            switch event {
            case .open(let name, let attributes, let selfClosing):
                switch name {
                case "channel":
                    if let id = attributes["id"] { channel = Channel(id: id) }
                case "programme":
                    guard let id = attributes["channel"], let start = attributes["start"].flatMap(Self.date), let stop = attributes["stop"].flatMap(Self.date) ?? Optional(start.addingTimeInterval(1800)) else { break }
                    if let channelIDs, !channelIDs.contains(id) { break }
                    if let window, stop <= window.start || start >= window.end { break }
                    programme = Programme(channel: id, start: start, stop: stop)
                case "icon":
                    let url = attributes["src"].flatMap { URL(string: $0) }
                    if var current = programme {
                        if current.icon == nil { current.icon = url }
                        programme = current
                    } else if var current = channel {
                        if current.icon == nil { current.icon = url }
                        channel = current
                    }
                case "new": programme?.isNew = true
                case "premiere": programme?.isPremiere = true
                case "live": programme?.isLive = true
                case "episode-num": episodeSystem = attributes["system"] ?? ""
                case "rating": inRating = true
                default: break
                }
                if !selfClosing, ["display-name", "title", "sub-title", "desc", "category", "episode-num", "value"].contains(name) { text = "" }
            case .text(let value):
                if text != nil { text? += value }
            case .close(let name):
                let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch name {
                case "display-name":
                    if !value.isEmpty { channel?.names.append(value) }
                case "title":
                    if programme?.title.isEmpty == true { programme?.title = value }
                case "sub-title":
                    if !value.isEmpty { programme?.subtitle = value }
                case "desc":
                    if !value.isEmpty, programme?.summary == nil { programme?.summary = value }
                case "category":
                    if !value.isEmpty, programme?.categories.contains(value) == false { programme?.categories.append(value) }
                case "episode-num":
                    if var current = programme, let numbers = Self.episodeNumbers(value, system: episodeSystem ?? "") {
                        if current.season == nil { current.season = numbers.season }
                        if current.episode == nil { current.episode = numbers.episode }
                        programme = current
                    }
                    episodeSystem = nil
                case "value":
                    if inRating, !value.isEmpty, programme?.rating == nil { programme?.rating = value }
                case "rating": inRating = false
                case "channel":
                    if let finished = channel { channels[finished.id] = finished }
                    channel = nil
                case "programme":
                    if let finished = programme, !finished.title.isEmpty { programmes[finished.channel, default: []].append(finished) }
                    programme = nil
                default: break
                }
                text = nil
            }
        }
        for key in programmes.keys { programmes[key]?.sort { $0.start < $1.start } }
        return XMLTVGuide(channels: channels, programmes: programmes)
    }

    /// XMLTV's time: `YYYYMMDDhhmmss` with an optional `±hhmm` offset, UTC when it has none; shorter forms drop the end.
    package static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let padded = Array(digits.prefix(14)) + Array(repeating: Character("0"), count: max(0, 14 - min(digits.count, 14)))
        func number(_ range: Range<Int>) -> Int { padded[range].reduce(0) { $0 * 10 + ($1.wholeNumberValue ?? 0) } }
        let (year, month, day) = (number(0..<4), number(4..<6), number(6..<8))
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86400 + number(8..<10) * 3600 + number(10..<12) * 60 + number(12..<14)
        var offset = 0
        let rest = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if let sign = rest.first, sign == "+" || sign == "-" {
            let value = rest.dropFirst().prefix(4)
            if value.count == 4, let hours = Int(value.prefix(2)), let minutes = Int(value.suffix(2)) {
                offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            }
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds - offset))
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm), which is far cheaper than a
    /// calendar for the hundred thousand times a large guide asks.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146097 + dayOfEra - 719468
    }

    /// Season and episode from `xmltv_ns` (`1.4.0/1`, counted from zero) or `onscreen`/`SxxEyy` styles.
    static func episodeNumbers(_ value: String, system: String) -> (season: Int?, episode: Int?)? {
        if system == "xmltv_ns" {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            func first(_ part: Substring) -> Int? { part.split(separator: "/").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { $0 + 1 } }
            let season = first(parts[0])
            let episode = first(parts[1])
            return season == nil && episode == nil ? nil : (season, episode)
        }
        let upper = value.uppercased()
        guard let s = upper.firstIndex(of: "S"), let e = upper[s...].firstIndex(of: "E") else { return nil }
        let season = Int(upper[upper.index(after: s)..<e].filter(\.isNumber))
        let episode = Int(upper[upper.index(after: e)...].prefix { $0.isNumber })
        return season == nil && episode == nil ? nil : (season, episode)
    }
}

/// A forward-only scanner over XML bytes giving tags and text, with entities and CDATA decoded; comments, processing
/// instructions and the doctype are skipped.
struct XMLScanner {
    enum Event {
        case open(String, [String: String], selfClosing: Bool)
        case text(String)
        case close(String)
    }

    private let bytes: [UInt8]
    private var index = 0
    private var pendingClose: String?

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
    }

    mutating func next() -> Event? {
        if let close = pendingClose {
            pendingClose = nil
            return .close(close)
        }
        while index < bytes.count {
            if bytes[index] != UInt8(ascii: "<") {
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "<") { index += 1 }
                return .text(Self.decodeEntities(bytes[start..<index]))
            }
            if matches("<!--") {
                index = find("-->", from: index + 4).map { $0 + 3 } ?? bytes.count
                continue
            }
            if matches("<![CDATA[") {
                let start = index + 9
                let end = find("]]>", from: start) ?? bytes.count
                index = min(end + 3, bytes.count)
                return .text(String(decoding: bytes[start..<end], as: UTF8.self))
            }
            if matches("<?") || matches("<!") {
                index = find(">", from: index).map { $0 + 1 } ?? bytes.count
                continue
            }
            if matches("</") {
                let start = index + 2
                let end = find(">", from: start) ?? bytes.count
                index = min(end + 1, bytes.count)
                return .close(String(decoding: bytes[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces))
            }
            return openTag()
        }
        return nil
    }

    private mutating func openTag() -> Event? {
        index += 1
        let nameStart = index
        while index < bytes.count, !Self.isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">"), bytes[index] != UInt8(ascii: "/") { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
        var attributes: [String: String] = [:]
        var selfClosing = false
        while index < bytes.count {
            let byte = bytes[index]
            if Self.isSpace(byte) {
                index += 1
            } else if byte == UInt8(ascii: ">") {
                index += 1
                break
            } else if byte == UInt8(ascii: "/") {
                selfClosing = true
                index += 1
            } else {
                let keyStart = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "="), !Self.isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") { index += 1 }
                let key = String(decoding: bytes[keyStart..<index], as: UTF8.self)
                while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
                guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { continue }
                index += 1
                while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
                guard index < bytes.count else { break }
                let quote = bytes[index]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    index += 1
                    let valueStart = index
                    while index < bytes.count, bytes[index] != quote { index += 1 }
                    attributes[key] = Self.decodeEntities(bytes[valueStart..<index])
                    index += 1
                } else {
                    let valueStart = index
                    while index < bytes.count, !Self.isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") { index += 1 }
                    attributes[key] = Self.decodeEntities(bytes[valueStart..<index])
                }
            }
        }
        if selfClosing { pendingClose = name }
        return .open(name, attributes, selfClosing: selfClosing)
    }

    private func matches(_ text: StaticString) -> Bool {
        let count = text.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        let pointer = text.utf8Start
        for offset in 0..<count where bytes[index + offset] != pointer[offset] { return false }
        return true
    }

    private func find(_ text: StaticString, from start: Int) -> Int? {
        let count = text.utf8CodeUnitCount
        let pointer = text.utf8Start
        var position = start
        while position + count <= bytes.count {
            if bytes[position] == pointer[0] {
                var hit = true
                for offset in 1..<count where bytes[position + offset] != pointer[offset] {
                    hit = false
                    break
                }
                if hit { return position }
            }
            position += 1
        }
        return nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    static func decodeEntities(_ slice: ArraySlice<UInt8>) -> String {
        guard slice.contains(UInt8(ascii: "&")) else { return String(decoding: slice, as: UTF8.self) }
        let text = String(decoding: slice, as: UTF8.self)
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 else {
                result += "&"
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let entity = rest[rest.index(after: amp)..<semi]
            switch entity {
            case "amp": result += "&"
            case "lt": result += "<"
            case "gt": result += ">"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += rest[amp...semi]
                }
            }
            rest = rest[rest.index(after: semi)...]
        }
        result += rest
        return result
    }
}
