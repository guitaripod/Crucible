import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The card that floats by an airing the pointer rests on in the guide: the channel, the title, when it airs and how long
/// is left or when it starts, the episode, the listing's description, and a few sentences from the person's own model on
/// what the programme is, which arrive a moment later and stay for the session. It never takes the pointer, so moving
/// along the guide passes straight through it.
@MainActor
final class LiveHoverCard: View {
    enum About: Equatable {
        case none
        case thinking
        case text(String)
    }

    private(set) var programID: String?
    private var channel = ""
    private var tags: [String] = []
    private var title = ""
    private var meta = ""
    private var summary = ""
    private var isOn = false
    var modelName: String?
    var about: About = .none {
        didSet {
            guard about != oldValue else { return }
            superview?.setNeedsLayout()
            setNeedsDisplay()
        }
    }

    func show(channel: LiveChannel, program: LiveProgram, now: Date = Date()) {
        let label = LiveChannelLabel(channel)
        programID = program.id
        self.channel = [label.number, label.name].compactMap { $0 }.joined(separator: "  ")
        tags = label.tags
        title = program.title
        isOn = program.isOn(at: now)
        var parts = [LiveGuideMath.timeRange(program)]
        parts.append(isOn ? LiveGuideMath.remaining(program, at: now) : LiveTVCopy.startsAt(program.start, now: now))
        parts += [program.episodeCode, program.episodeTitle, program.contentRating].compactMap { $0 }.filter { !$0.isEmpty }
        if !program.genres.isEmpty { parts.append(program.genres.prefix(2).joined(separator: ", ")) }
        meta = parts.joined(separator: "  ·  ")
        summary = program.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        about = .none
        setNeedsDisplay()
    }

    override var isPointerInteractive: Bool { false }
    override func hitTest(_ point: Point) -> View? { nil }

    private var metrics: Metrics { Theme.current.metrics }
    private var padding: Float { metrics.tv(28) }

    private func layouts(width: Float) -> (channel: TextLayout, title: TextLayout, meta: TextLayout, summary: TextLayout?, about: TextLayout?, source: TextLayout?)? {
        guard let scale = window?.scale else { return nil }
        let theme = Theme.current
        let inner = width - padding * 2
        let channelText = TextLayout(channel, font: theme.type.eyebrow, maxWidth: inner - metrics.tv(160), maxLines: 1, scale: scale)
        let titleText = TextLayout(title, font: theme.type.title3, maxWidth: inner, maxLines: 2, scale: scale)
        let metaText = TextLayout(meta, font: theme.type.footnote, maxWidth: inner, maxLines: 2, scale: scale)
        let summaryText = summary.isEmpty ? nil : TextLayout(summary, font: theme.type.callout, maxWidth: inner, maxLines: 4, scale: scale)
        var aboutText: TextLayout?
        var sourceText: TextLayout?
        switch about {
        case .none: break
        case .thinking:
            aboutText = TextLayout(LiveTVCopy.aboutThinking, font: theme.type.callout, maxWidth: inner, maxLines: 1, scale: scale)
        case .text(let text):
            aboutText = TextLayout(text, font: theme.type.callout, maxWidth: inner, maxLines: 6, scale: scale)
        }
        if about != .none, let modelName {
            sourceText = TextLayout(modelName, font: theme.type.caption2, maxWidth: inner - metrics.tv(40), maxLines: 1, scale: scale)
        }
        return (channelText, titleText, metaText, summaryText, aboutText, sourceText)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        guard let made = layouts(width: size.width) else { return Size(width: size.width, height: 0) }
        var height = padding * 2 + made.channel.size.height + metrics.tv(10) + made.title.size.height + metrics.tv(8) + made.meta.size.height
        if let summary = made.summary { height += metrics.tv(16) + summary.size.height }
        if let about = made.about { height += metrics.tv(26) + metrics.tv(34) + about.size.height }
        return Size(width: size.width, height: height.rounded(.up))
    }

    override func draw(_ context: inout DrawContext) {
        guard let made = layouts(width: bounds.width) else { return }
        let theme = Theme.current
        let palette = theme.palette
        let card = bounds
        context.shadow(card, radius: metrics.radiusM, blur: metrics.tv(40), offsetY: metrics.tv(14), opacity: 0.5)
        context.fill(card, radius: metrics.radiusM, color: palette.surfaceHigh)
        context.stroke(card, radius: metrics.radiusM, width: 1, color: palette.separator)
        var y = padding
        var x = padding
        if isOn {
            let badge = TextLayout(LiveTVCopy.live, font: theme.type.badge, maxLines: 1, scale: window?.scale ?? 1)
            let rect = Rect(x: x, y: y + (made.channel.size.height - badge.size.height - metrics.tv(6)) / 2, width: badge.size.width + metrics.tv(16),
                            height: badge.size.height + metrics.tv(6))
            context.fill(rect, radius: metrics.radiusXS, color: palette.destructive)
            context.text(badge, at: Point(x: rect.x + metrics.tv(8), y: rect.y + metrics.tv(3)), color: .white)
            x = rect.maxX + metrics.tv(12)
        }
        context.text(made.channel, at: Point(x: x, y: y), color: palette.accentText)
        x += made.channel.size.width + metrics.tv(12)
        for tag in tags {
            let label = TextLayout(tag, font: Font(size: theme.type.caption2.size, weight: .semibold), maxLines: 1, scale: window?.scale ?? 1)
            let rect = Rect(x: x, y: y + (made.channel.size.height - label.size.height - metrics.tv(6)) / 2, width: label.size.width + metrics.tv(14),
                            height: label.size.height + metrics.tv(6))
            context.stroke(rect, radius: metrics.tv(5), width: metrics.tv(2), color: palette.labelTertiary)
            context.text(label, at: Point(x: rect.x + metrics.tv(7), y: rect.y + metrics.tv(3)), color: palette.labelSecondary)
            x = rect.maxX + metrics.tv(6)
        }
        y += made.channel.size.height + metrics.tv(10)
        context.text(made.title, at: Point(x: padding, y: y), color: palette.label)
        y += made.title.size.height + metrics.tv(8)
        context.text(made.meta, at: Point(x: padding, y: y), color: palette.labelSecondary)
        y += made.meta.size.height
        if let summary = made.summary {
            y += metrics.tv(16)
            context.text(summary, at: Point(x: padding, y: y), color: palette.label.withSRGBAlpha(0.86))
            y += summary.size.height
        }
        guard let aboutText = made.about else { return }
        y += metrics.tv(26)
        context.fill(Rect(x: padding, y: y - metrics.tv(13), width: bounds.width - padding * 2, height: 1), color: palette.separator)
        let side = metrics.tv(26)
        context.symbol("sparkles", in: Rect(x: padding, y: y, width: side, height: side), color: palette.accent)
        if let source = made.source {
            context.text(source, at: Point(x: padding + side + metrics.tv(10), y: (y + (side - source.size.height) / 2).rounded()), color: palette.labelTertiary)
        }
        y += metrics.tv(34)
        context.text(aboutText, at: Point(x: padding, y: y), color: about == .thinking ? palette.labelTertiary : palette.label)
    }
}
