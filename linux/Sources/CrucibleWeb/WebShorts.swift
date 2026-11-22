import Foundation

extension WebEntry {
    /// The addresses of a Short's own upright picture, which a list names only sometimes: the site keeps it under one of
    /// two names and a frame of the clip under a third, then the sixteen by nine picture every video has. `sharp` puts the
    /// full-size pictures first, for the picture standing in for the clip itself; a card takes the list's smaller one.
    package func shortThumbnailCandidates(sharp: Bool) -> [String] {
        guard let video = WebLink.youTubeVideoID(in: url) ?? (kind == .video && id.count == 11 && url.contains("youtu") ? id : nil) else {
            return thumbnailCandidates
        }
        let listed = thumbnail.flatMap { $0.contains("/oar") || $0.contains("/sar") ? $0 : nil }
        let upright = ["oardefault", "sardefault", "oar2"].map { "https://i.ytimg.com/vi/\(video)/\($0).jpg" }
        let candidates = (sharp ? upright + [listed] : [listed] + upright).compactMap { $0 } + ["https://i.ytimg.com/vi/\(video)/hq720.jpg"]
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }
}

/// What the Shorts player decides without a screen: the order of its feed, the picture worth fetching for the size it
/// shows at, which clips are kept ready, and when one counts as watched.
package enum WebShorts {
    /// The Shorts among `entries`, each once, those the viewer has not seen ahead of those they have, each group in the
    /// order it came in.
    package static func lineUp(_ entries: [WebEntry], isWatched: (String) -> Bool) -> [WebEntry] {
        var seen: Set<String> = []
        let shorts = entries.filter { $0.kind == .video && $0.isShort && seen.insert($0.id).inserted }
        return shorts.filter { !isWatched($0.id) } + shorts.filter { isWatched($0.id) }
    }

    /// `more` after `feed`, leaving out what the feed already has.
    package static func extended(_ feed: [WebEntry], with more: [WebEntry]) -> [WebEntry] {
        var seen = Set(feed.map(\.id))
        return feed + more.filter { $0.kind == .video && seen.insert($0.id).inserted }
    }

    /// The tallest picture worth playing in a pane of `paneWidth` by `paneHeight` pixels: the smallest of the video's
    /// pictures that fills the pane as it is fitted there (within a tenth), so a clip filmed in 4K is not fetched to be
    /// shown a quarter of that size. `shortSide` is the viewer's own limit ("1080p"), which for an upright picture is its
    /// width. Nil when the video names no sizes.
    package static func heightLimit(of video: WebVideo, paneWidth: Int, paneHeight: Int, shortSide: Int?) -> Int? {
        var sizes: [(width: Int, height: Int)] = []
        for format in video.formats where format.hasVideo {
            guard let width = format.width, let height = format.height, width > 0, height > 0 else { continue }
            if !sizes.contains(where: { $0.width == width && $0.height == height }) { sizes.append((width, height)) }
        }
        guard !sizes.isEmpty else { return nil }
        if let shortSide {
            let within = sizes.filter { min($0.width, $0.height) <= shortSide }
            let least = sizes.map { min($0.width, $0.height) }.min() ?? 0
            sizes = within.isEmpty ? sizes.filter { min($0.width, $0.height) == least } : within
        }
        sizes.sort { $0.height < $1.height }
        let filling = sizes.first { size in
            let shown = min(Double(paneHeight), Double(paneWidth) * Double(size.height) / Double(size.width))
            return Double(size.height) >= shown * 0.9
        }
        return (filling ?? sizes[sizes.count - 1]).height
    }

    /// The clips kept open around the one playing, the most wanted first: the one playing, the one after it, which is
    /// opened and held at its first frame so a swipe shows it at once, and the one before it while it is still open.
    package static func kept(around index: Int, count: Int) -> [Int] {
        [index, index + 1, index - 1].filter { $0 >= 0 && $0 < count }
    }

    /// Whether a clip played to `position` has been watched: most of it, or all but its last second and a half.
    package static func isWatched(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return position >= duration * 0.7 || duration - position <= 1.5
    }
}

/// Turns a wheel, a touchpad's fingers and a drag into steps through the feed. A wheel's notch is one clip, with a pause
/// between steps so a spin of the wheel does not fly past a dozen; fingers and a drag pull the feed along with them, and
/// letting go moves on when the pull went far or fast enough and falls back otherwise. At either end of the feed the pull
/// stretches and gives.
package struct WebShortsPager: Sendable {
    /// The least time between two steps of the wheel, in seconds.
    package static let wheelPause: Double = 0.24
    /// How far of a page a pull must go to move on when it is let go at rest.
    package static let pullThreshold: Float = 0.18
    /// The speed, in pages a second, at which a flick moves on however short it was.
    package static let flickSpeed: Float = 1.1

    package var canGoBack = false
    package var canGoOn = false
    /// How far the feed is pulled from rest, in pages: positive toward the next clip.
    package private(set) var pull: Float = 0
    private var notches: Float = 0
    private var lastNotch: Double = -.infinity
    private var lastStep: Double = -.infinity
    private var speed: Float = 0
    private var lastMove: Double = -.infinity

    package init() {}

    /// Takes `amount` notches of the wheel (positive toward the next clip) and returns the step it makes: -1, 0 or 1.
    package mutating func wheel(_ amount: Float, at time: Double) -> Int {
        if time - lastNotch > 0.4 || (notches != 0 && (notches > 0) != (amount > 0)) { notches = 0 }
        lastNotch = time
        notches += amount
        guard abs(notches) >= 1, time - lastStep >= Self.wheelPause else {
            if abs(notches) > 1 { notches = notches > 0 ? 1 : -1 }
            return 0
        }
        let step = notches > 0 ? 1 : -1
        notches = 0
        guard step > 0 ? canGoOn : canGoBack else { return 0 }
        lastStep = time
        return step
    }

    /// Moves the pull by `pages` (positive toward the next clip) and returns where the feed is drawn.
    package mutating func drag(by pages: Float, at time: Double) -> Float {
        let elapsed = Float(time - lastMove)
        if elapsed > 0, elapsed < 0.25 {
            speed = speed * 0.5 + (pages / elapsed) * 0.5
        } else {
            speed = 0
        }
        lastMove = time
        pull = min(max(pull + pages, -1), 1)
        return shown
    }

    /// The pull as it is drawn: one to one where there is a clip to go to, a third of it and no more than a seventh of a
    /// page where there is none.
    package var shown: Float {
        let free = pull > 0 ? canGoOn : canGoBack
        return free ? pull : max(min(pull / 3, 0.14), -0.14)
    }

    /// Lets go of the pull at `time` and returns the step it makes: -1, 0 or 1.
    package mutating func release(at time: Double) -> Int {
        defer {
            pull = 0
            speed = 0
        }
        let flick = time - lastMove < 0.12 ? speed : 0
        var step = 0
        if pull > Self.pullThreshold || (flick > Self.flickSpeed && pull > 0.02) { step = 1 }
        if pull < -Self.pullThreshold || (flick < -Self.flickSpeed && pull < -0.02) { step = -1 }
        guard step != 0, step > 0 ? canGoOn : canGoBack else { return 0 }
        lastStep = time
        return step
    }
}
