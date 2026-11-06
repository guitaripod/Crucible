import Foundation

extension DemoLibrary {
    /// Downloaded subtitles number their streams from here, clear of every title's own stream ids.
    private static let downloadedStreamBase = 1_000_000

    private static let languageNames = ["en": "English", "fi": "Finnish", "es": "Spanish", "fr": "French", "de": "German", "sv": "Swedish"]

    /// Three subtitles an online catalogue might offer for any title, in the language asked for.
    func subtitleSearchResponse(_ key: String, language: String) -> DemoResponse {
        guard items[key] != nil else { return .notFound() }
        let name = Self.languageNames[language] ?? language.uppercased()
        let candidates: [DemoJSON] = [
            ["key": "/library/metadata/\(key)/subtitles/\(language)/1", "codec": "srt", "format": "srt", "language": name, "languageCode": language,
             "providerTitle": "OpenSubtitles", "title": "\(name) (SRT)", "score": 96, "perfectMatch": true, "hearingImpaired": false, "forced": false],
            ["key": "/library/metadata/\(key)/subtitles/\(language)/2", "codec": "srt", "format": "srt", "language": name, "languageCode": language,
             "providerTitle": "OpenSubtitles", "title": "\(name) SDH (SRT)", "score": 81, "perfectMatch": false, "hearingImpaired": true, "forced": false],
            ["key": "/library/metadata/\(key)/subtitles/\(language)/3", "codec": "srt", "format": "srt", "language": name, "languageCode": language,
             "providerTitle": "Podnapisi", "title": "\(name) (SRT)", "score": 44, "perfectMatch": false, "hearingImpaired": false, "forced": false],
        ]
        return .container(["size": candidates.count, "Stream": candidates])
    }

    /// Keeps a found subtitle: it joins the title's own subtitle tracks, which the next metadata read lists.
    func downloadSubtitle(_ key: String, language: String, name: String, hearingImpaired: Bool) -> DemoResponse {
        guard let item = items[key], item.isPlayable else { return .notFound() }
        let id = Self.downloadedStreamBase + (Int(key) ?? 0) * 100 + (downloadedSubtitles[key]?.count ?? 0)
        let label = Self.languageNames[language] ?? name
        let stream: DemoJSON = [
            "id": id, "streamType": 3, "codec": "srt", "format": "srt", "language": label, "languageCode": language, "languageTag": language,
            "displayTitle": "\(label)\(hearingImpaired ? " SDH" : "") (SRT)", "default": false, "forced": false, "selected": false,
            "hearingImpaired": hearingImpaired, "key": "/library/streams/\(id)",
        ]
        downloadedSubtitles[key, default: []].append(stream)
        return .empty()
    }

    /// The SubRip text of subtitle stream `id`: a downloaded one in its own language, otherwise the title's own track the id names.
    func subtitleText(forStream id: Int) -> String {
        for stream in downloadedSubtitles.values.joined() where stream.int("id") == id {
            return DemoSubtitles.srt(language: stream.string("languageCode") ?? "en", hearingImpaired: stream["hearingImpaired"] as? Bool ?? false)
        }
        return DemoSubtitles.srt(forStream: id)
    }
}
