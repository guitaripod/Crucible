import Foundation

/// A comment's text as Trakt stores it, read into runs a screen can style: Markdown emphasis, code and links, quoted lines,
/// inline `[spoiler]…[/spoiler]` tags, and emoji short codes such as `:joy:` turned into the emoji itself.
package struct TraktCommentText: Equatable, Sendable {
    package enum Style: Hashable, Sendable {
        case bold
        case italic
        case strike
        case code
        case quote
        case link(URL)
    }

    package struct Run: Equatable, Sendable {
        package var text: String
        package var styles: Set<Style>
        package var isSpoiler: Bool

        package init(text: String, styles: Set<Style> = [], isSpoiler: Bool = false) {
            self.text = text
            self.styles = styles
            self.isSpoiler = isSpoiler
        }

        package var link: URL? {
            for style in styles { if case .link(let url) = style { return url } }
            return nil
        }
    }

    package let runs: [Run]

    package init(_ raw: String) {
        let text = Self.replacingShortCodes(in: raw.replacingOccurrences(of: "\r\n", with: "\n"))
        let marked = Self.markingSpoilers(text)
        var runs: [Run] = []
        var start = 0
        for line in Self.lines(marked.characters) {
            let flags = Array(marked.spoiler[start..<(start + line.count)])
            start += line.count
            var characters = line
            var lineFlags = flags
            var styles: Set<Style> = []
            if let quoted = Self.quoteStart(line) {
                styles.insert(.quote)
                characters.removeSubrange(quoted)
                lineFlags.removeSubrange(quoted)
            }
            for run in InlineParser(characters, spoiler: lineFlags).parse() {
                Self.append(Run(text: run.text, styles: run.styles.union(styles), isSpoiler: run.isSpoiler), to: &runs)
            }
        }
        self.runs = runs
    }

    /// Whether any part of the text is hidden behind a spoiler tag.
    package var hasInlineSpoilers: Bool { runs.contains(where: \.isSpoiler) }

    /// The text without its Markdown, every spoiler shown.
    package var plainText: String { runs.map(\.text).joined() }

    /// The text without its Markdown, each spoiler replaced by a word that says one is there, for a preview or VoiceOver.
    package var textHidingSpoilers: String {
        var result = ""
        var inSpoiler = false
        for run in runs {
            if run.isSpoiler {
                if !inSpoiler { result += "[\(TraktCommunityCopy.spoilerWord)]" }
                inSpoiler = true
            } else {
                inSpoiler = false
                result += run.text
            }
        }
        return result
    }

    private static func append(_ run: Run, to runs: inout [Run]) {
        guard !run.text.isEmpty else { return }
        if let last = runs.last, last.styles == run.styles, last.isSpoiler == run.isSpoiler {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(run)
        }
    }

    /// The text without its spoiler tags, with whether each character sits inside one. Tags match in any case; an opening tag
    /// without its closing one hides the rest.
    static func markingSpoilers(_ text: String) -> (characters: [Character], spoiler: [Bool]) {
        var characters: [Character] = []
        var spoiler: [Bool] = []
        var rest = Substring(text)
        var inSpoiler = false
        while !rest.isEmpty {
            let tag = inSpoiler ? "[/spoiler]" : "[spoiler]"
            guard let range = rest.range(of: tag, options: .caseInsensitive) else {
                characters += rest
                spoiler += Array(repeating: inSpoiler, count: rest.count)
                break
            }
            let before = rest[..<range.lowerBound]
            characters += before
            spoiler += Array(repeating: inSpoiler, count: before.count)
            rest = rest[range.upperBound...]
            inSpoiler.toggle()
        }
        return (characters, spoiler)
    }

    /// The lines of `characters`, each keeping its line break so the runs join back into the same layout.
    private static func lines(_ characters: [Character]) -> [[Character]] {
        var result: [[Character]] = []
        var current: [Character] = []
        for character in characters {
            current.append(character)
            if character == "\n" {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The marker of a Markdown quote line (`> text`, its leading spaces and the space after it), or nil for any other line.
    private static func quoteStart(_ line: [Character]) -> Range<Int>? {
        var index = 0
        while index < line.count, line[index] == " " { index += 1 }
        guard index < line.count, line[index] == ">" else { return nil }
        let end = index + 1 < line.count && line[index + 1] == " " ? index + 2 : index + 1
        return 0..<end
    }

    /// Emoji written as short codes (`:joy:`), as Trakt may return them, shown as the emoji. Unknown codes stay as written.
    static func replacingShortCodes(in text: String) -> String {
        guard text.contains(":") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == ":", let close = text[text.index(after: index)...].firstIndex(of: ":") {
                let name = text[text.index(after: index)..<close]
                if !name.isEmpty, name.count <= 40, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }),
                   let emoji = TraktEmoji.shortCodes[name.lowercased()] {
                    result += emoji
                    index = text.index(after: close)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }
}

/// Reads one line of Markdown's inline syntax. A marker without its closing partner stays as written, so a lone asterisk or an
/// underscore inside a word is never taken for emphasis.
private struct InlineParser {
    private let characters: [Character]
    private let spoiler: [Bool]

    init(_ characters: [Character], spoiler: [Bool]) {
        self.characters = characters
        self.spoiler = spoiler
    }

    func parse() -> [TraktCommentText.Run] {
        parse(range: 0..<characters.count, styles: [])
    }

    /// The characters of `range` as runs of `styles`, cut wherever a spoiler starts or ends.
    private func runs(_ range: Range<Int>, styles: Set<TraktCommentText.Style>) -> [TraktCommentText.Run] {
        var runs: [TraktCommentText.Run] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let hidden = spoiler[index]
            var end = index
            while end < range.upperBound, spoiler[end] == hidden { end += 1 }
            runs.append(TraktCommentText.Run(text: String(characters[index..<end]), styles: styles, isSpoiler: hidden))
            index = end
        }
        return runs
    }

    private func parse(range: Range<Int>, styles: Set<TraktCommentText.Style>) -> [TraktCommentText.Run] {
        var runs: [TraktCommentText.Run] = []
        var plainStart = range.lowerBound
        var plainExtra: [(index: Int, character: Character)] = []
        func flush(upTo end: Int) {
            guard plainStart < end || !plainExtra.isEmpty else { return }
            var text: [Character] = []
            var flags: [Bool] = []
            var extra = plainExtra.makeIterator()
            var pending = extra.next()
            var index = plainStart
            while index < end {
                if let escape = pending, escape.index == index {
                    text.append(escape.character)
                    flags.append(spoiler[index])
                    index += 2
                    pending = extra.next()
                    continue
                }
                text.append(characters[index])
                flags.append(spoiler[index])
                index += 1
            }
            runs += InlineParser(text, spoiler: flags).runs(0..<text.count, styles: styles)
            plainExtra = []
        }
        var index = range.lowerBound
        while index < range.upperBound {
            let character = characters[index]
            if character == "\\", index + 1 < range.upperBound, "*_`~[]()\\>".contains(characters[index + 1]) {
                plainExtra.append((index, characters[index + 1]))
                index += 2
                continue
            }
            if character == "`", let close = find("`", from: index + 1, before: range.upperBound), close > index + 1 {
                flush(upTo: index)
                runs += self.runs((index + 1)..<close, styles: styles.union([.code]))
                index = close + 1
                plainStart = index
                continue
            }
            if character == "[", let link = link(at: index, before: range.upperBound) {
                flush(upTo: index)
                runs += parse(range: link.label, styles: styles.union([.link(link.url)]))
                index = link.end
                plainStart = index
                continue
            }
            if let url = bareLink(at: index, before: range.upperBound) {
                flush(upTo: index)
                runs += self.runs(index..<url.end, styles: styles.union([.link(url.url)]))
                index = url.end
                plainStart = index
                continue
            }
            if let emphasis = emphasis(at: index, before: range.upperBound) {
                flush(upTo: index)
                runs += parse(range: emphasis.inner, styles: styles.union([emphasis.style]))
                index = emphasis.end
                plainStart = index
                continue
            }
            index += 1
        }
        flush(upTo: range.upperBound)
        return runs
    }

    private func find(_ marker: Character, from start: Int, before end: Int) -> Int? {
        var index = start
        while index < end {
            if characters[index] == marker { return index }
            index += 1
        }
        return nil
    }

    private func matches(_ marker: [Character], at index: Int, before end: Int) -> Bool {
        guard index + marker.count <= end else { return false }
        return Array(characters[index..<(index + marker.count)]) == marker
    }

    private func isWordCharacter(_ index: Int) -> Bool {
        guard index >= 0, index < characters.count else { return false }
        return characters[index].isLetter || characters[index].isNumber
    }

    /// `**bold**`, `__bold__`, `*italic*`, `_italic_` and `~~struck~~`: an opener followed by text, closed by the same marker
    /// right after text. Underscores also need a word boundary outside them, so snake_case stays as written.
    private func emphasis(at index: Int, before end: Int) -> (style: TraktCommentText.Style, inner: Range<Int>, end: Int)? {
        let candidates: [([Character], TraktCommentText.Style)] = [
            (["*", "*"], .bold), (["_", "_"], .bold), (["~", "~"], .strike), (["*"], .italic), (["_"], .italic),
        ]
        for (marker, style) in candidates where matches(marker, at: index, before: end) {
            let innerStart = index + marker.count
            guard innerStart < end, !characters[innerStart].isWhitespace else { continue }
            if marker.first == "_", isWordCharacter(index - 1) { continue }
            var search = innerStart + 1
            while search + marker.count <= end {
                if matches(marker, at: search, before: end), !characters[search - 1].isWhitespace,
                   marker.first != "_" || !isWordCharacter(search + marker.count),
                   marker.count == 2 || !matches(marker + marker, at: search, before: end) {
                    return (style, innerStart..<search, search + marker.count)
                }
                search += 1
            }
        }
        return nil
    }

    /// `[label](https://…)`, with an address Crucible can open.
    private func link(at index: Int, before end: Int) -> (label: Range<Int>, url: URL, end: Int)? {
        guard let closeLabel = find("]", from: index + 1, before: end), closeLabel > index + 1,
              closeLabel + 1 < end, characters[closeLabel + 1] == "(",
              let closeURL = find(")", from: closeLabel + 2, before: end) else { return nil }
        let address = String(characters[(closeLabel + 2)..<closeURL]).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return ((index + 1)..<closeLabel, url, closeURL + 1)
    }

    /// An address written out (`https://…`), up to the next space, without trailing punctuation.
    private func bareLink(at index: Int, before end: Int) -> (url: URL, end: Int)? {
        guard characters[index] == "h", !isWordCharacter(index - 1),
              matches(Array("https://"), at: index, before: end) || matches(Array("http://"), at: index, before: end) else { return nil }
        var stop = index
        while stop < end, !characters[stop].isWhitespace { stop += 1 }
        while stop > index, ".,;:!?)\"'".contains(characters[stop - 1]) { stop -= 1 }
        guard let url = URL(string: String(characters[index..<stop])), url.host?.isEmpty == false else { return nil }
        return (url, stop)
    }
}

/// What a comment being written is, measured against Trakt's rules: at least five words, a review from 200 words, English
/// only, spoilers marked, and nothing that advertises the app it was written in.
package struct TraktCommentDraft: Equatable, Sendable {
    package static let minimumWords = 5
    package static let reviewWords = 200

    package enum Concern: Equatable, Sendable {
        /// Fewer words than Trakt takes; carries how many more are needed.
        case tooShort(missing: Int)
        /// Mostly written in letters English does not use.
        case notEnglish
        /// Names the app it was written in, which Trakt forbids.
        case appTag
    }

    package let text: String
    package let wordCount: Int

    package init(_ text: String) {
        self.text = text
        wordCount = Self.countWords(text)
    }

    /// The words Trakt counts: runs of letters or digits, with spoiler tags and Markdown markers not counted.
    package static func countWords(_ text: String) -> Int {
        let stripped = text.replacingOccurrences(of: "[spoiler]", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "[/spoiler]", with: " ", options: .caseInsensitive)
        return stripped.split(whereSeparator: { $0.isWhitespace }).filter { word in word.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    package var canPost: Bool { wordCount >= Self.minimumWords && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether Trakt will mark it a review.
    package var isReview: Bool { wordCount >= Self.reviewWords }

    /// How far it is toward a review, from 0 to 1.
    package var reviewProgress: Double { min(1, Double(wordCount) / Double(Self.reviewWords)) }

    package var concerns: [Concern] {
        var concerns: [Concern] = []
        if wordCount < Self.minimumWords { concerns.append(.tooShort(missing: Self.minimumWords - wordCount)) }
        if Self.looksNotEnglish(text) { concerns.append(.notEnglish) }
        if Self.namesTheApp(text) { concerns.append(.appTag) }
        return concerns
    }

    /// More than a third of the letters are outside the Latin alphabet, so Trakt would likely refuse it as not English.
    static func looksNotEnglish(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 12 else { return false }
        let foreign = letters.filter { $0.value > 0x024F }.count
        return Double(foreign) / Double(letters.count) > 0.34
    }

    private static func namesTheApp(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("via crucible") || lowered.contains("#crucible") || lowered.contains("sent from crucible")
    }

    /// `text` with `range` wrapped in spoiler tags, and where the cursor goes after: inside the tags when nothing was
    /// selected, after the closing tag otherwise.
    package static func wrappingSpoiler(_ text: String, range: NSRange) -> (text: String, cursor: NSRange) {
        let source = text as NSString
        let safe = NSRange(location: min(range.location, source.length), length: min(range.length, max(0, source.length - range.location)))
        let selected = source.substring(with: safe)
        let wrapped = "[spoiler]\(selected)[/spoiler]"
        let result = source.replacingCharacters(in: safe, with: wrapped)
        let openLength = ("[spoiler]" as NSString).length
        let cursor = safe.length == 0
            ? NSRange(location: safe.location + openLength, length: 0)
            : NSRange(location: safe.location + (wrapped as NSString).length, length: 0)
        return (result, cursor)
    }
}

/// The emoji short codes Trakt's website uses (JoyPixels), for the ones its API returns as codes instead of emoji.
enum TraktEmoji {
    static let shortCodes: [String: String] = [
        "smile": "😄", "smiley": "😃", "grin": "😁", "grinning": "😀", "joy": "😂", "laughing": "😆", "satisfied": "😆", "rofl": "🤣",
        "wink": "😉", "blush": "😊", "innocent": "😇", "heart_eyes": "😍", "star_struck": "🤩", "kissing_heart": "😘",
        "yum": "😋", "stuck_out_tongue": "😛", "stuck_out_tongue_winking_eye": "😜", "zany_face": "🤪", "money_mouth": "🤑",
        "hugging": "🤗", "hugs": "🤗", "thinking": "🤔", "shushing_face": "🤫", "zipper_mouth": "🤐", "raised_eyebrow": "🤨",
        "face_with_raised_eyebrow": "🤨", "neutral_face": "😐", "expressionless": "😑", "no_mouth": "😶", "smirk": "😏",
        "unamused": "😒", "roll_eyes": "🙄", "rolling_eyes": "🙄", "grimacing": "😬", "relieved": "😌", "pensive": "😔",
        "sleepy": "😪", "sleeping": "😴", "yawning_face": "🥱", "mask": "😷", "nauseated_face": "🤢", "vomiting_face": "🤮",
        "sneezing_face": "🤧", "hot_face": "🥵", "cold_face": "🥶", "woozy_face": "🥴", "dizzy_face": "😵", "exploding_head": "🤯",
        "cowboy": "🤠", "partying_face": "🥳", "sunglasses": "😎", "nerd": "🤓", "confused": "😕", "worried": "😟",
        "slight_frown": "🙁", "slightly_frowning_face": "🙁", "frowning": "😦", "open_mouth": "😮", "hushed": "😯",
        "astonished": "😲", "flushed": "😳", "pleading_face": "🥺", "anguished": "😧", "fearful": "😨", "cold_sweat": "😰",
        "disappointed_relieved": "😥", "cry": "😢", "sob": "😭", "scream": "😱", "confounded": "😖", "persevere": "😣",
        "disappointed": "😞", "sweat": "😓", "weary": "😩", "tired_face": "😫", "triumph": "😤", "rage": "😡", "angry": "😠",
        "smiling_imp": "😈", "imp": "👿", "skull": "💀", "skull_crossbones": "☠️", "poop": "💩", "clown": "🤡",
        "ghost": "👻", "alien": "👽", "robot": "🤖", "see_no_evil": "🙈", "hear_no_evil": "🙉", "speak_no_evil": "🙊",
        "slight_smile": "🙂", "slightly_smiling_face": "🙂", "upside_down": "🙃", "upside_down_face": "🙃",
        "sweat_smile": "😅", "smiling_face_with_tear": "🥲", "melting_face": "🫠", "saluting_face": "🫡",
        "face_palm": "🤦", "facepalm": "🤦", "shrug": "🤷", "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎",
        "clap": "👏", "raised_hands": "🙌", "pray": "🙏", "ok_hand": "👌", "wave": "👋", "muscle": "💪", "metal": "🤘",
        "v": "✌️", "crossed_fingers": "🤞", "point_up": "☝️", "point_right": "👉", "point_left": "👈", "handshake": "🤝",
        "eyes": "👀", "fire": "🔥", "100": "💯", "heart": "❤️", "broken_heart": "💔", "sparkling_heart": "💖", "sparkles": "✨",
        "star": "⭐", "star2": "🌟", "boom": "💥", "tada": "🎉", "trophy": "🏆", "crown": "👑", "gem": "💎", "rocket": "🚀",
        "popcorn": "🍿", "movie_camera": "🎥", "clapper": "🎬", "tv": "📺", "film_frames": "🎞️", "ticket": "🎫",
        "warning": "⚠️", "x": "❌", "white_check_mark": "✅", "question": "❓", "exclamation": "❗", "zzz": "💤",
        "bomb": "💣", "knife": "🔪", "drop_of_blood": "🩸", "coffin": "⚰️", "unicorn": "🦄", "dragon": "🐉", "cat": "🐱",
        "dog": "🐶", "goat": "🐐", "brain": "🧠", "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉",
    ]
}
