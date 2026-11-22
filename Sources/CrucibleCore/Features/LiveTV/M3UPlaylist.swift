import Foundation

/// An extended M3U channel playlist, the format IPTV services hand out: `#EXTM3U` with the guide's address, then one
/// `#EXTINF` line of attributes and a name per channel, followed by its address.
package struct M3UPlaylist: Sendable, Equatable {
    package struct Entry: Sendable, Equatable {
        package var title: String
        package var url: URL
        package var attributes: [String: String]
        package var group: String?
        package var userAgent: String?
        package var referrer: String?

        package var tvgID: String? { attributes["tvg-id"].flatMap(Self.nonEmpty) }
        package var tvgName: String? { attributes["tvg-name"].flatMap(Self.nonEmpty) }
        package var logo: URL? { (attributes["tvg-logo"] ?? attributes["logo"]).flatMap(Self.nonEmpty).flatMap(URL.init(string:)) }
        package var number: String? { (attributes["tvg-chno"] ?? attributes["channel-number"] ?? attributes["tvg-num"]).flatMap(Self.nonEmpty) }

        /// The groups the entry is filed under: `group-title` (which may list several, split by semicolons), else `#EXTGRP`.
        package var groups: [String] {
            let raw = attributes["group-title"].flatMap(Self.nonEmpty) ?? group
            return raw?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        }

        private static func nonEmpty(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    package var entries: [Entry]
    /// The guide addresses the header names (`x-tvg-url`, `url-tvg`, `tvg-url`), which may list several split by commas.
    package var guideURLs: [URL]

    package enum ParseError: Error, Equatable {
        case notAPlaylist
        case empty
    }

    /// Reads `text`; a playlist without the `#EXTM3U` header is accepted when it has `#EXTINF` lines.
    package static func parse(_ text: String) throws -> M3UPlaylist {
        var entries: [Entry] = []
        var guideURLs: [URL] = []
        var pending: (title: String, attributes: [String: String])?
        var group: String?
        var userAgent: String?
        var referrer: String?
        var sawHeader = false
        var sawInfo = false
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = Substring(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTM3U") {
                sawHeader = true
                let attributes = attributes(in: Substring(line.dropFirst("#EXTM3U".count)))
                for key in ["x-tvg-url", "url-tvg", "tvg-url"] {
                    guard let value = attributes[key] else { continue }
                    for part in value.split(separator: ",") {
                        let address = part.trimmingCharacters(in: .whitespaces)
                        if let url = URL(string: address), url.scheme != nil, !guideURLs.contains(url) { guideURLs.append(url) }
                    }
                }
            } else if line.hasPrefix("#EXTINF:") {
                sawInfo = true
                pending = info(Substring(line.dropFirst("#EXTINF:".count)))
            } else if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst("#EXTVLCOPT:".count)
                if let value = Self.value(of: "http-user-agent", in: option) { userAgent = value }
                if let value = Self.value(of: "http-referrer", in: option) ?? Self.value(of: "http-referer", in: option) { referrer = value }
            } else if line.hasPrefix("#") {
                continue
            } else {
                let (address, headers) = Self.addressAndHeaders(line)
                guard let url = URL(string: address), url.scheme != nil else { continue }
                let info = pending ?? (title: url.lastPathComponent, attributes: [:])
                entries.append(Entry(title: info.title, url: url, attributes: info.attributes, group: group,
                                     userAgent: headers["user-agent"] ?? userAgent, referrer: headers["referer"] ?? headers["referrer"] ?? referrer))
                pending = nil
                group = nil
                userAgent = nil
                referrer = nil
            }
        }
        guard sawHeader || sawInfo else { throw ParseError.notAPlaylist }
        guard !entries.isEmpty else { throw ParseError.empty }
        return M3UPlaylist(entries: entries, guideURLs: guideURLs)
    }

    /// The duration, attributes and display name of an `#EXTINF` line. The name follows the first comma outside quotes.
    private static func info(_ body: Substring) -> (title: String, attributes: [String: String]) {
        var inQuotes = false
        var split: Substring.Index?
        for index in body.indices {
            let character = body[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                split = index
                break
            }
        }
        guard let split else { return (body.trimmingCharacters(in: .whitespaces), attributes(in: body)) }
        let head = body[..<split]
        let title = body[body.index(after: split)...].trimmingCharacters(in: .whitespaces)
        let attributes = attributes(in: head)
        return (title.isEmpty ? (attributes["tvg-name"] ?? "") : title, attributes)
    }

    /// `key="value"` pairs (quotes optional), with keys lowercased.
    static func attributes(in text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace || text[index] == "," { index = text.index(after: index) }
            let keyStart = index
            while index < text.endIndex, text[index] != "=", !text[index].isWhitespace { index = text.index(after: index) }
            let key = text[keyStart..<index].lowercased()
            guard index < text.endIndex, text[index] == "=" else {
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            index = text.index(after: index)
            var value = ""
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                let valueStart = index
                while index < text.endIndex, text[index] != "\"" { index = text.index(after: index) }
                value = String(text[valueStart..<index])
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                let valueStart = index
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
                value = String(text[valueStart..<index])
            }
            if !key.isEmpty, !key.hasPrefix("-") { result[key] = value }
        }
        return result
    }

    /// An address line, which may carry headers after a pipe (`http://…|User-Agent=…&Referer=…`, as Kodi writes them).
    private static func addressAndHeaders(_ line: String) -> (String, [String: String]) {
        guard let pipe = line.firstIndex(of: "|") else { return (line, [:]) }
        var headers: [String: String] = [:]
        for pair in line[line.index(after: pipe)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return (String(line[..<pipe]), headers)
    }

    private static func value(of key: String, in option: Substring) -> String? {
        guard option.lowercased().hasPrefix(key + "=") else { return nil }
        return String(option.dropFirst(key.count + 1))
    }
}
