import Foundation

extension TraktCommentText {
    /// One line of a comment: its runs without the line break, whether it is quoted, whether a break followed it, and
    /// whether that break sat inside a spoiler that goes on to the next line.
    package struct Line: Equatable, Sendable {
        package var runs: [Run]
        package var isQuote: Bool
        package var endsWithBreak: Bool
        package var breakIsSpoiler: Bool

        package init(runs: [Run], isQuote: Bool = false, endsWithBreak: Bool = false, breakIsSpoiler: Bool = false) {
            self.runs = runs
            self.isQuote = isQuote
            self.endsWithBreak = endsWithBreak
            self.breakIsSpoiler = breakIsSpoiler
        }

        /// The line's words without its Markdown.
        package var plainText: String { runs.map(\.text).joined() }

        /// Whether the line holds anything worth translating: a letter outside code and links.
        package var hasWords: Bool {
            runs.contains { run in
                run.link == nil && !run.styles.contains(.code) && run.text.contains { $0.isLetter }
            }
        }
    }

    /// The text cut into its lines, each run without its line break and without the quote style, which the line carries.
    package var lines: [Line] {
        var result: [Line] = []
        var current: [Run] = []
        var isQuote = false
        func finish(endsWithBreak: Bool, breakIsSpoiler: Bool = false) {
            result.append(Line(runs: current, isQuote: isQuote, endsWithBreak: endsWithBreak, breakIsSpoiler: breakIsSpoiler))
            current = []
            isQuote = false
        }
        for run in runs {
            var styles = run.styles
            if styles.remove(.quote) != nil { isQuote = true }
            let pieces = run.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if !piece.isEmpty { current.append(Run(text: String(piece), styles: styles, isSpoiler: run.isSpoiler)) }
                if index < pieces.count - 1 { finish(endsWithBreak: true, breakIsSpoiler: run.isSpoiler) }
            }
        }
        if !current.isEmpty || isQuote { finish(endsWithBreak: false) }
        return result
    }

    /// Comment text in the form Trakt stores, which reads back into the same lines: Markdown emphasis, code and links,
    /// quoted lines and spoiler tags, a spoiler staying open across a break that sat inside it. Plain text is written as
    /// it is while it reads back the same; where it would not, as with a literal asterisk or two emphases side by side,
    /// Markdown's characters are escaped, and failing that the emphasis is dropped so the words and spoilers stay right.
    package static func markup(_ lines: [Line]) -> String {
        for escaping in [false, true] {
            let candidate = write(lines, escaping: escaping, emphasis: true)
            if readsBack(candidate, as: lines) { return candidate }
        }
        return write(lines, escaping: true, emphasis: false)
    }

    private static func write(_ lines: [Line], escaping: Bool, emphasis: Bool) -> String {
        var result = ""
        var inSpoiler = false
        func spoiler(_ on: Bool) {
            guard on != inSpoiler else { return }
            result += on ? "[spoiler]" : "[/spoiler]"
            inSpoiler = on
        }
        for line in lines {
            if line.isQuote { result += "> " }
            for run in line.runs {
                spoiler(run.isSpoiler)
                result += markup(run, escaping: escaping, emphasis: emphasis)
            }
            spoiler(line.endsWithBreak && line.breakIsSpoiler)
            if line.endsWithBreak { result += "\n" }
        }
        spoiler(false)
        return result
    }

    /// Whether `markup` reads back into the same words, with every letter as hidden, quoted and styled as in `lines`.
    /// Spaces may move in or out of a style, which changes nothing on screen.
    private static func readsBack(_ markup: String, as lines: [Line]) -> Bool {
        let read = TraktCommentText(markup).lines
        guard read.count == lines.count else { return false }
        for (got, wanted) in zip(read, lines) {
            guard got.isQuote == wanted.isQuote, got.endsWithBreak == wanted.endsWithBreak else { return false }
            let a = characters(of: got)
            let b = characters(of: wanted)
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) {
                guard x.character == y.character else { return false }
                if x.character.isWhitespace { continue }
                guard x.isSpoiler == y.isSpoiler, x.styles == y.styles else { return false }
            }
        }
        return true
    }

    private static func characters(of line: Line) -> [(character: Character, styles: Set<Style>, isSpoiler: Bool)] {
        line.runs.flatMap { run in run.text.map { ($0, run.styles, run.isSpoiler) } }
    }

    /// The characters Markdown would read as markers, escaped with a backslash as the parser reads them back.
    private static let markers: Set<Character> = ["\\", "*", "_", "`", "~", "[", "]", "(", ")", ">"]

    /// One run with its Markdown, its outer whitespace kept outside the markers so they still read as emphasis.
    private static func markup(_ run: Run, escaping: Bool, emphasis: Bool) -> String {
        let text = run.text
        let leading = String(text.prefix { $0.isWhitespace })
        let rest = text.dropFirst(leading.count)
        let trailing = String(rest.reversed().prefix { $0.isWhitespace }.reversed())
        let core = String(rest.dropLast(trailing.count))
        guard !core.isEmpty else { return text }
        let isCode = run.styles.contains(.code)
        let isBareLink = run.link?.absoluteString == core
        var body = escaping && !isCode && !isBareLink ? core.map { markers.contains($0) ? "\\\($0)" : String($0) }.joined() : core
        if isCode {
            body = "`\(body)`"
        } else if emphasis {
            if run.styles.contains(.strike) { body = "~~\(body)~~" }
            if run.styles.contains(.italic) { body = "*\(body)*" }
            if run.styles.contains(.bold) { body = "**\(body)**" }
        }
        if let url = run.link, !isBareLink {
            body = "[\(body)](\(url.absoluteString))"
        }
        return leading + body + trailing
    }
}
