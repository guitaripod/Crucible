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
    /// quoted lines and spoiler tags, a spoiler staying open across a break that sat inside it.
    package static func markup(_ lines: [Line]) -> String {
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
                result += markup(run)
            }
            spoiler(line.endsWithBreak && line.breakIsSpoiler)
            if line.endsWithBreak { result += "\n" }
        }
        spoiler(false)
        return result
    }

    /// One run with its Markdown, its outer whitespace kept outside the markers so they still read as emphasis.
    private static func markup(_ run: Run) -> String {
        let text = run.text
        let leading = String(text.prefix { $0.isWhitespace })
        let rest = text.dropFirst(leading.count)
        let trailing = String(rest.reversed().prefix { $0.isWhitespace }.reversed())
        let core = String(rest.dropLast(trailing.count))
        guard !core.isEmpty else { return text }
        var body = core
        if run.styles.contains(.code) {
            body = "`\(body)`"
        } else {
            if run.styles.contains(.strike) { body = "~~\(body)~~" }
            if run.styles.contains(.italic) { body = "*\(body)*" }
            if run.styles.contains(.bold) { body = "**\(body)**" }
        }
        if let url = run.link {
            body = core == url.absoluteString && !run.styles.contains(.code) ? core : "[\(body)](\(url.absoluteString))"
        }
        return leading + body + trailing
    }
}
