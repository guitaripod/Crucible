import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The transport of a live channel: in place of the title's timeline, the airing's own, from when it began to when it ends
/// on the wall clock, filled up to now and moving with it, so it never jumps as the stream's buffer grows; above it a LIVE
/// mark, the channel, what airs, the episode and what airs next. After a pause the mark shows how far behind live playback
/// is, the part not yet seen is drawn faint, and Go Live returns to now.
extension TransportView {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func liveTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// The header above a live channel's bar on a desk: the LIVE mark and the channel, what airs in large type, then its
    /// episode and what airs next.
    func drawLiveHeader(_ live: LiveAiring, label: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let goLive = isBehindLive ? metrics.tv(330) : 0
        let width = (isCompact ? deskTopRowX - deskInset - metrics.tv(24) : frame.width - deskInset * 2 - goLive)
        var y = metrics.tv(30)
        let markHeight = drawLiveMark(at: Point(x: deskInset, y: y), scale: scale, context: &context)
        var x = deskInset + markHeight.width + metrics.tv(18)
        let channel = TextLayout(live.channel, font: theme.type.callout, maxWidth: max(width - x + deskInset, metrics.tv(40)), maxLines: 1, scale: scale)
        context.text(channel, at: Point(x: x, y: (y + (markHeight.height - channel.size.height) / 2).rounded()), color: theme.palette.accentText)
        x += channel.size.width + metrics.tv(14)
        for tag in live.tags {
            x += drawTag(tag, at: Point(x: x, y: y + markHeight.height / 2), label: label, scale: scale, context: &context) + metrics.tv(8)
        }
        y += markHeight.height + metrics.tv(8)
        let title = TextLayout(live.title, font: theme.type.headline, maxWidth: width, maxLines: 1, scale: scale)
        context.text(title, at: Point(x: deskInset, y: y.rounded()), color: label)
        y += title.size.height + metrics.tv(4)
        let line = [live.detail, live.next].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ·   ")
        guard !line.isEmpty else { return }
        let detail = TextLayout(line, font: theme.type.callout, maxWidth: frame.width - deskInset * 2 - goLive, maxLines: 1, scale: scale)
        context.text(detail, at: Point(x: deskInset, y: y.rounded()), color: label.withAlpha(0.68))
    }

    /// The couch's line under the title: the episode and what airs next.
    func drawLiveCouchDetail(_ live: LiveAiring, below titleBottom: Float, maxWidth: Float, scale: Float, context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let line = [live.detail, live.next].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        guard !line.isEmpty else { return }
        let detail = TextLayout(line, font: Theme.current.type.caption1, maxWidth: maxWidth, maxLines: 1, scale: scale)
        let origin = Point(x: metrics.tv(48), y: (titleBottom + metrics.tv(6)).rounded())
        context.text(detail, at: origin, color: GlassStyle.secondaryLabel(tone: labelTone(.detail, over: Rect(origin: origin, size: detail.size), context)))
    }

    /// LIVE on red at the live edge; after a pause, how far behind on a quiet pill. Returns the mark's size.
    @discardableResult
    private func drawLiveMark(at origin: Point, scale: Float, context: inout DrawContext) -> Size {
        let theme = Theme.current
        let metrics = theme.metrics
        let behind = isBehindLive
        let text = behind ? "−" + Self.clock(behindLive) : LiveTVCopy.live
        let layout = TextLayout(text, font: Font(size: theme.type.caption1.size, weight: .bold), maxLines: 1, scale: scale)
        let size = Size(width: layout.size.width + metrics.tv(28), height: layout.size.height + metrics.tv(10))
        let rect = Rect(origin: origin, size: size)
        context.fill(rect, radius: metrics.tv(8), color: behind ? Color.white.withAlpha(0.18) : theme.palette.destructive)
        context.text(layout, at: Point(x: (rect.midX - layout.size.width / 2).rounded(), y: (rect.midY - layout.size.height / 2).rounded()), color: .white)
        return size
    }

    /// A small outlined tag ("US", "FHD") centred on `origin.y`; returns its width.
    private func drawTag(_ text: String, at origin: Point, label: Color, scale: Float, context: inout DrawContext) -> Float {
        let metrics = Theme.current.metrics
        let layout = TextLayout(text, font: Font(size: Theme.current.type.caption2.size, weight: .semibold), maxLines: 1, scale: scale)
        let rect = Rect(x: origin.x, y: (origin.y - layout.size.height / 2 - metrics.tv(4)).rounded(), width: layout.size.width + metrics.tv(16),
                        height: layout.size.height + metrics.tv(8))
        context.stroke(rect, radius: metrics.tv(6), width: metrics.tv(2), color: label.withAlpha(0.45))
        context.text(layout, at: Point(x: rect.x + metrics.tv(8), y: rect.y + metrics.tv(4)), color: label.withAlpha(0.85))
        return rect.width
    }

    func drawGoLive(in rect: Rect, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard rect.width > 0 else { return }
        context.fill(rect, radius: rect.height / 2, color: theme.palette.accent)
        let side = metrics.tv(30)
        let text = TextLayout(String(localized: "Go Live", comment: "Player button: jump back to what airs now on a live channel after a pause"),
                              font: theme.type.control, maxLines: 1, scale: scale)
        let total = side + metrics.tv(12) + text.size.width
        let left = rect.midX - total / 2
        context.symbol("forward.end.fill", in: Rect(x: left, y: rect.midY - side / 2, width: side, height: side), color: theme.palette.onAccent)
        context.text(text, at: Point(x: (left + side + metrics.tv(12)).rounded(), y: (rect.midY - text.size.height / 2).rounded()), color: theme.palette.onAccent)
    }

    /// The airing's bar: start and end times at either side, filled to now, the knob where playback is.
    func drawLiveBar(_ live: LiveAiring, label: Color, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let track = bar
        let now = Date()
        let accent = theme.palette.accent
        context.fill(track, radius: track.height / 2, color: label.withAlpha(0.22))
        let timeFont = isDesk ? theme.type.control : theme.type.caption1
        var leading = Self.liveTime(now)
        var trailing = ""
        if let start = live.start, let end = live.end, end > start {
            let total = end.timeIntervalSince(start)
            let edge = Float(min(max(now.timeIntervalSince(start) / total, 0), 1))
            let played = Float(min(max((now.timeIntervalSince(start) - behindLive) / total, 0), 1))
            context.fill(Rect(x: track.x, y: track.y, width: max(track.width * edge, track.height), height: track.height), radius: track.height / 2,
                         color: isBehindLive ? accent.withAlpha(0.38) : accent)
            if isBehindLive {
                context.fill(Rect(x: track.x, y: track.y, width: max(track.width * played, track.height), height: track.height), radius: track.height / 2, color: accent)
            }
            let knob = isDesk ? metrics.tv(26) : metrics.tv(22)
            context.fill(Rect(x: track.x + track.width * played - knob / 2, y: track.midY - knob / 2, width: knob, height: knob), radius: knob / 2, color: .white)
            leading = Self.liveTime(start)
            trailing = Self.liveTime(end)
            if let hoverFraction {
                let moment = start.addingTimeInterval(total * Double(hoverFraction))
                let preview = TextLayout(Self.liveTime(moment), font: isDesk ? theme.type.callout : theme.type.caption1, scale: scale)
                let anchor = track.x + track.width * hoverFraction
                let tick = metrics.tv(4)
                context.fill(Rect(x: (anchor - tick / 2).rounded(), y: track.y - metrics.tv(6), width: tick, height: track.height + metrics.tv(12)),
                             radius: tick / 2, color: label.withAlpha(0.85))
                let origin = Point(x: min(max(anchor - preview.size.width / 2, track.x), track.maxX - preview.size.width),
                                   y: track.y - preview.size.height - metrics.tv(14))
                context.text(preview, at: origin, color: isDesk ? label : GlassStyle.label(tone: labelTone(.preview, over: Rect(origin: origin, size: preview.size), context)))
            }
        } else {
            context.fill(track, radius: track.height / 2, color: accent.withAlpha(isBehindLive ? 0.38 : 0.85))
        }
        let start = TextLayout(leading, font: timeFont, scale: scale)
        let end = TextLayout(trailing, font: timeFont, scale: scale)
        let startOrigin: Point
        let endOrigin: Point
        if isDesk {
            startOrigin = Point(x: deskInset, y: (track.midY - start.size.height / 2).rounded())
            endOrigin = Point(x: frame.width - deskInset - end.size.width, y: (track.midY - end.size.height / 2).rounded())
        } else {
            startOrigin = Point(x: track.x, y: track.maxY + metrics.tv(8))
            endOrigin = Point(x: track.maxX - end.size.width, y: track.maxY + metrics.tv(8))
        }
        let timeColor = { (tone: Float) in self.isDesk ? label : GlassStyle.secondaryLabel(tone: tone) }
        context.text(start, at: startOrigin, color: timeColor(labelTone(.elapsed, over: Rect(origin: startOrigin, size: start.size), context)))
        if !trailing.isEmpty {
            context.text(end, at: endOrigin, color: timeColor(labelTone(.remaining, over: Rect(origin: endOrigin, size: end.size), context)))
        }
        if buffering {
            let note = TextLayout(String(localized: "Buffering…"), font: theme.type.caption1, scale: scale)
            let origin = Point(x: track.midX - note.size.width / 2, y: track.maxY + metrics.tv(isDesk ? 12 : 8))
            context.text(note, at: origin, color: GlassStyle.secondaryLabel(tone: labelTone(.buffering, over: Rect(origin: origin, size: note.size), context)))
        }
    }
}
