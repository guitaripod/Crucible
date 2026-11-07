import Foundation

/// The subtitle text the demo serves for every title: a few lines timed to fit the demo clip.
enum DemoSubtitles {
    private static let cues: [(start: String, end: String)] = [
        ("00:00:02,000", "00:00:05,000"), ("00:00:06,000", "00:00:09,500"), ("00:00:12,000", "00:00:15,000"),
        ("00:00:17,000", "00:00:20,000"), ("00:00:22,000", "00:00:25,000"), ("00:00:26,000", "00:00:29,000"),
    ]

    private static let english = [
        "We should not be out here.", "The tide turns in an hour. Then we go.", "Someone has been down there before us.",
        "Keep the light low and the radio off.", "Whatever they left, it is still ticking.", "Hold on. This is the last of it.",
    ]
    private static let sdh = [
        "[waves lapping] We should not be out here.", "The tide turns in an hour. Then we go.",
        "[distant bell] Someone has been down there before us.", "Keep the light low and the radio off.",
        "[machinery ticking] Whatever they left, it is still ticking.", "[wind rising] Hold on. This is the last of it.",
    ]
    private static let spanish = [
        "No deberíamos estar aquí.", "La marea cambia en una hora. Entonces nos vamos.", "Alguien ha estado ahí abajo antes que nosotros.",
        "Mantén la luz baja y la radio apagada.", "Lo que dejaran, todavía sigue haciendo tictac.", "Agárrate. Esto es lo último.",
    ]
    private static let finnish = [
        "Meidän ei pitäisi olla täällä.", "Vuorovesi kääntyy tunnin päästä. Sitten lähdemme.", "Joku on käynyt siellä alhaalla ennen meitä.",
        "Pidä valo himmeänä ja radio pois päältä.", "Mitä he jättivätkin, se tikittää yhä.", "Pidä kiinni. Tämä on viimeinen.",
    ]

    /// The SubRip text for subtitle stream `streamID` of a title's own tracks; the last digit of a stream id says which of the five
    /// tracks it is.
    static func srt(forStream streamID: Int) -> String {
        switch streamID % 10 {
        case 6: return srt(sdh)
        case 7: return srt(spanish)
        case 8: return srt(finnish)
        default: return srt(english)
        }
    }

    /// The SubRip text of a subtitle found online, in its language: Spanish and Finnish have their own lines, everything else reads
    /// in English.
    static func srt(language: String, hearingImpaired: Bool) -> String {
        switch language {
        case "es": return srt(spanish)
        case "fi": return srt(finnish)
        default: return srt(hearingImpaired ? sdh : english)
        }
    }

    /// SubRip text as one WebVTT segment on the clip's own timeline, which starts at zero.
    static func webVTT(fromSubRip srt: String) -> String {
        let cues = srt.components(separatedBy: "\n\n").compactMap { block -> String? in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            guard let timing = lines.first, timing.contains("-->") else { return nil }
            return ([timing.replacingOccurrences(of: ",", with: ".")] + lines.dropFirst().map(String.init)).joined(separator: "\n")
        }
        return (["WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"] + cues).joined(separator: "\n\n") + "\n"
    }

    private static func srt(_ lines: [String]) -> String {
        zip(cues, lines).enumerated()
            .map { "\($0.offset + 1)\n\($0.element.0.start) --> \($0.element.0.end)\n\($0.element.1)\n" }
            .joined(separator: "\n")
    }
}
