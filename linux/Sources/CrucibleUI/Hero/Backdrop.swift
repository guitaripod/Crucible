import Foundation
import Kiln

/// Full-screen artwork behind a screen (`TVBackdropView`) with the three canvas-tinted scrims that keep text, shelves and
/// the tab bar legible over any picture. `show` waits out rapid focus changes and cross-fades; `dimming` pushes the
/// picture back as content scrolls over it.
@MainActor
public final class BackdropView: View {
    private struct Layer {
        let source: ArtworkSource
        let texture: Texture
        var opacity: Animated
    }

    public var dimming: Float = 0 { didSet { if dimming != oldValue { setNeedsDisplay() } } }

    private var layers: [Layer] = []
    private var fadingOut: [Layer] = []
    private var requested: ArtworkSource?
    private var pending: Task<Void, Never>?

    /// Cross-fades to `source` after the debounce (or at once when `immediate`); nil fades to the canvas.
    public func show(_ source: ArtworkSource?, immediate: Bool = false) {
        guard source != requested else { return }
        requested = source
        pending?.cancel()
        pending = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: UInt64(Durations.backdropDebounce * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.load(source)
        }
    }

    private func load(_ source: ArtworkSource?) async {
        guard let source else {
            fadingOut += layers
            layers.removeAll()
            for index in fadingOut.indices { fadingOut[index].opacity.set(0, animation: .backdrop) }
            startAnimating()
            return
        }
        if layers.last?.source == source { return }
        guard let window, let store = window.images else { return }
        let pixelWidth = Int((max(frame.width, 1) * window.scale).rounded(.up))
        let pixelHeight = Int((max(frame.height, 1) * window.scale).rounded(.up))
        guard let request = source.request(pixelWidth: pixelWidth, pixelHeight: pixelHeight), let texture = await store.load(request) else {
            if requested == source { requested = nil }
            return
        }
        guard !Task.isCancelled, requested == source else { return }
        var opacity = Animated(0)
        opacity.set(1, animation: .backdrop)
        layers.append(Layer(source: source, texture: texture, opacity: opacity))
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        var moving = false
        for index in layers.indices where layers[index].opacity.advance(dt) { moving = true }
        for index in fadingOut.indices where fadingOut[index].opacity.advance(dt) { moving = true }
        fadingOut.removeAll { $0.opacity.value <= 0.001 }
        if let top = layers.last, top.opacity.value >= 0.999, layers.count > 1 {
            layers.removeFirst(layers.count - 1)
        }
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let metrics = Theme.current.metrics
        let canvas = palette.canvas
        context.fill(bounds, color: canvas)
        for layer in fadingOut + layers {
            context.image(layer.texture, in: bounds, opacity: layer.opacity.value)
        }
        let textScrim = Rect(x: 0, y: 0, width: bounds.width * 0.78, height: bounds.height)
        context.gradient(textScrim, vertical: false, stops: [
            (0, canvas.overlay(0.96)), (0.42 / 0.78, canvas.overlay(0.78)), (0.8, canvas.overlay(0.3)), (1, canvas.overlay(0)),
        ])
        let bottom = Rect(x: 0, y: bounds.height * 0.35, width: bounds.width, height: bounds.height * 0.65)
        context.gradient(bottom, vertical: true, stops: [
            (0, canvas.overlay(0)), (0.25, canvas.overlay(0.3)), ((0.72 - 0.35) / 0.65, canvas.overlay(0.7)), (1, canvas.overlay(1)),
        ])
        let top = Rect(x: 0, y: 0, width: bounds.width, height: metrics.backdropTopScrim)
        context.gradient(top, vertical: true, stops: [
            (0, canvas.overlay(0.85)), (0.45, canvas.overlay(0.4)), (0.8, canvas.overlay(0.1)), (1, canvas.overlay(0)),
        ])
        if dimming > 0 {
            context.fill(bounds, color: canvas.overlay(min(max(dimming, 0), 1) * metrics.backdropMaximumDimming))
        }
    }
}

/// A score drawn after the facts under its source's mark (`RatingLine`): Plex's star, or a service's mark from
/// `BrandMarks` (`imdb`, `rottentomatoes-fresh`).
public struct HeroRating: Hashable, Sendable {
    public enum Mark: Hashable, Sendable {
        case star
        case brand(String, isWordmark: Bool)
    }

    public var mark: Mark?
    public var text: String
    /// The score as a screen reader says it, the source named ("IMDb 8.1").
    public var spoken: String?

    public init(mark: Mark?, text: String, spoken: String? = nil) {
        self.mark = mark
        self.text = text
        self.spoken = spoken
    }
}

/// What the hero block shows (`TVHeroInfo`).
public struct HeroInfo: Hashable, Sendable {
    public enum TitleStyle: Sendable { case title2, title1 }

    public var eyebrow: String?
    public var title: String
    public var metaParts: [String]
    public var ratings: [HeroRating]
    public var badges: [String]
    public var synopsis: String?
    public var progress: Double?
    public var titleStyle: TitleStyle
    /// What a screen reader reads for the whole block (`TVHeroInfo.accessibilityText`); built from the fields when nil.
    public var spokenText: String?

    public init(eyebrow: String? = nil, title: String, metaParts: [String] = [], ratings: [HeroRating] = [], badges: [String] = [],
                synopsis: String? = nil, progress: Double? = nil, titleStyle: TitleStyle = .title2, spokenText: String? = nil) {
        self.spokenText = spokenText
        self.eyebrow = eyebrow
        self.title = title
        self.metaParts = metaParts
        self.ratings = ratings
        self.badges = badges
        self.synopsis = synopsis
        self.progress = progress
        self.titleStyle = titleStyle
    }
}

/// The text over a backdrop (`TVHeroInfoView`): eyebrow, title, a middle-dot fact line, outlined badges, the synopsis and
/// a thin progress bar, bottom-aligned in a fixed height. A long title and synopsis give way rather than overflow: the
/// synopsis loses lines first (3, 2, 1), then the title drops to one line, then the synopsis goes. Changes cross-dissolve.
/// Its text can be selected and copied; the view takes the pointer only over text, so what lies behind keeps the rest.
@MainActor
public final class HeroInfoView: View, TextSelecting {
    private var info: HeroInfo?
    private var previous: HeroInfo?
    private var crossfade = Animated(1)
    private let selector = TextSelector()

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        selector.onChange = { [weak self] in self?.setNeedsDisplay() }
    }

    public var selectedText: String? { selector.selectedText }
    public func clearSelection() { selector.clear() }
    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .text }

    /// The block as one spoken summary (`TVHeroInfoView.spokenText`): title, eyebrow, facts and scores, badges, synopsis.
    public override var accessibilityLabel: String? {
        guard let info else { return nil }
        if let spoken = info.spokenText, !spoken.isEmpty { return spoken }
        let facts = (info.metaParts.filter { !$0.isEmpty } + info.ratings.map { $0.spoken ?? $0.text }).joined(separator: ", ")
        let badges = info.badges.isEmpty ? nil : info.badges.joined(separator: ", ")
        return [info.title, info.eyebrow, facts, badges, info.synopsis].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    public override var accessibilityValue: String? {
        guard let progress = info?.progress, progress > 0, progress < 1 else { return nil }
        return String(format: Strings.lookup("%lld percent watched"), Int((progress * 100).rounded()))
    }

    public override var accessibilityRole: AccessibilityRole { info == nil ? .none : .label }

    public override func hitTest(_ point: Point) -> View? {
        let hit = super.hitTest(point)
        return hit === self && selector.block(at: point) == nil ? nil : hit
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        SelectableText.press(button, at: point, selector: selector, in: self)
    }

    public override func pointerDragged(to point: Point) { selector.drag(to: point) }
    public override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) { selector.release() }

    public func configure(_ newInfo: HeroInfo?, animated: Bool) {
        guard newInfo != info else { return }
        if newInfo?.title != info?.title { selector.clear() }
        previous = animated ? info : nil
        info = newInfo
        if animated {
            crossfade.reset(0)
            crossfade.set(1, animation: .timed(duration: Durations.heroText, curve: .easeInOut))
            startAnimating()
        } else {
            crossfade.reset(1)
        }
        setNeedsDisplay()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = crossfade.advance(dt)
        if !moving { previous = nil }
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        selector.beginDrawing()
        if let previous, crossfade.value < 1 {
            context.faded(1 - crossfade.value) { inner in draw(previous, selectable: false, context: &inner) }
        }
        if let info {
            context.faded(crossfade.value) { inner in draw(info, selectable: true, context: &inner) }
        }
    }

    private struct Block {
        enum Kind { case text(TextLayout, Color), meta(TextLayout?, [(HeroRating.Mark?, TextLayout)], Font), badges([TextLayout]), progress(Float) }
        let kind: Kind
        let height: Float
        let spacingAfter: Float
    }

    private func blocks(for info: HeroInfo, titleLines: Int, synopsisLines: Int) -> [Block] {
        guard let scale = window?.scale else { return [] }
        let theme = Theme.current
        let type = theme.type
        let palette = theme.palette
        let metrics = theme.metrics
        let width = min(frame.width, metrics.heroTextColumn)
        let spacing = metrics.heroBlockSpacing
        var result: [Block] = []
        if let eyebrow = info.eyebrow, !eyebrow.isEmpty {
            let layout = TextLayout(eyebrow.uppercased(), font: type.caption1, maxWidth: width, scale: scale)
            result.append(Block(kind: .text(layout, palette.accentText), height: layout.size.height, spacingAfter: spacing))
        }
        let titleFont = info.titleStyle == .title1 ? type.title1 : type.title2
        let title = TextLayout(info.title, font: titleFont, maxWidth: width, maxLines: titleLines, scale: scale)
        result.append(Block(kind: .text(title, palette.label), height: title.size.height, spacingAfter: spacing + metrics.tv(6)))
        let meta = info.metaParts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        if !meta.isEmpty || !info.ratings.isEmpty {
            let layout = meta.isEmpty ? nil : TextLayout(meta, font: type.callout, maxWidth: width, scale: scale)
            let ratings = info.ratings.map { ($0.mark, TextLayout($0.text, font: type.callout, scale: scale)) }
            let height = max(layout?.size.height ?? 0, ratings.map(\.1.size.height).max() ?? 0)
            result.append(Block(kind: .meta(layout, ratings, type.callout), height: height, spacingAfter: spacing))
        }
        if !info.badges.isEmpty {
            let layouts = info.badges.map { TextLayout($0, font: type.badge, scale: scale) }
            let height = (layouts.map(\.size.height).max() ?? 0) + metrics.badgeInsetVertical * 2
            result.append(Block(kind: .badges(layouts), height: height, spacingAfter: spacing))
        }
        if synopsisLines > 0, let synopsis = info.synopsis, !synopsis.isEmpty {
            let layout = TextLayout(synopsis, font: type.body, maxWidth: width, maxLines: synopsisLines, scale: scale)
            result.append(Block(kind: .text(layout, palette.labelSecondary), height: layout.size.height, spacingAfter: spacing))
        }
        if let progress = info.progress, progress > 0, progress < 1 {
            result.append(Block(kind: .progress(Float(progress)), height: metrics.progressBarThickness, spacingAfter: 0))
        }
        return result
    }

    private func fitted(_ info: HeroInfo) -> [Block] {
        var titleLines = 2
        var synopsisLines = 3
        while true {
            let laidOut = blocks(for: info, titleLines: titleLines, synopsisLines: synopsisLines)
            let height = laidOut.reduce(0) { $0 + $1.height } + laidOut.dropLast().reduce(0) { $0 + $1.spacingAfter }
            if height <= frame.height + 0.5 { return laidOut }
            if synopsisLines > 1 {
                synopsisLines -= 1
            } else if titleLines > 1 {
                titleLines -= 1
            } else if synopsisLines > 0 {
                synopsisLines = 0
            } else {
                return laidOut
            }
        }
    }

    /// One state of the text; `selectable` registers its text blocks with the selector (the current state, never the one
    /// fading out).
    private func draw(_ info: HeroInfo, selectable: Bool, context: inout DrawContext) {
        let laidOut = fitted(info)
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let total = laidOut.reduce(0) { $0 + $1.height } + laidOut.dropLast().reduce(0) { $0 + $1.spacingAfter }
        var y = frame.height - total
        for (index, block) in laidOut.enumerated() {
            switch block.kind {
            case .text(let layout, let color):
                if selectable { selector.draw(layout, key: "text.\(index)", at: Point(x: 0, y: y), color: SelectableText.highlight, in: &context) }
                context.text(layout, at: Point(x: 0, y: y), color: color)
            case .meta(let layout, let ratings, let font):
                if selectable, let layout {
                    selector.draw(layout, key: "meta", at: Point(x: 0, y: y), color: SelectableText.highlight, in: &context)
                }
                drawMeta(layout, ratings: ratings, font: font, at: y, context: &context)
            case .badges(let layouts):
                var x: Float = 0
                for layout in layouts {
                    let size = Size(width: layout.size.width + metrics.badgeInsetHorizontal * 2, height: block.height)
                    context.stroke(Rect(x: x, y: y, width: size.width, height: size.height), radius: metrics.radiusXS,
                                   width: max(metrics.tv(2), 1), color: palette.labelTertiary)
                    context.text(layout, at: Point(x: x + metrics.badgeInsetHorizontal, y: y + metrics.badgeInsetVertical), color: palette.labelSecondary)
                    x += size.width + metrics.tv(16)
                }
            case .progress(let progress):
                ProgressBarStyle.draw(progress: progress, in: Rect(x: 0, y: y, width: metrics.tv(420), height: block.height), onArt: true, context: &context)
            }
            y += block.height + block.spacingAfter
        }
    }

    /// The fact line, then each score under its mark, joined by the line's middle dots; scores that would run past the
    /// text column are left out rather than clipped.
    private func drawMeta(_ layout: TextLayout?, ratings: [(HeroRating.Mark?, TextLayout)], font: Font, at y: Float, context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let palette = Theme.current.palette
        let column = min(frame.width, Theme.current.metrics.heroTextColumn)
        let separator = TextLayout("  ·  ", font: font, scale: scale)
        let capHeight = font.size * 0.727
        var x: Float = 0
        if let layout {
            context.text(layout, at: Point(x: 0, y: y), color: palette.labelSecondary)
            x = layout.size.width
        }
        for (index, (mark, text)) in ratings.enumerated() {
            let markSize = markSize(mark, capHeight: capHeight)
            let gap = mark == nil ? 0 : font.size * 0.28
            let leading = index == 0 && layout == nil ? 0 : separator.size.width
            guard x + leading + markSize.width + gap + text.size.width <= column else { break }
            if leading > 0 { context.text(separator, at: Point(x: x, y: y), color: palette.labelSecondary) }
            x += leading
            let markRect = Rect(x: x, y: y + text.baseline - capHeight / 2 - markSize.height / 2, width: markSize.width, height: markSize.height)
            switch mark {
            case .star:
                context.symbol("star.fill", in: markRect, color: palette.accent)
            case .brand(let name, _):
                if let gpu = window?.gpu, let texture = BrandMarks.texture(name, gpu: gpu) { context.image(texture, in: markRect) }
            case nil:
                break
            }
            x += markSize.width + gap
            context.text(text, at: Point(x: x, y: y), color: palette.labelSecondary)
            x += text.size.width
        }
    }

    /// A mark sized to the line's capitals: Plex's star a little taller, a wordmark (IMDb) a little shorter than a logo.
    private func markSize(_ mark: HeroRating.Mark?, capHeight: Float) -> Size {
        switch mark {
        case nil:
            return Size(width: 0, height: 0)
        case .star:
            return Size(width: (capHeight * 1.3).rounded(), height: (capHeight * 1.3).rounded())
        case .brand(let name, let isWordmark):
            let height = (capHeight * (isWordmark ? 1.35 : 1.5)).rounded()
            guard let gpu = window?.gpu, let texture = BrandMarks.texture(name, gpu: gpu), texture.height > 0 else { return Size(width: height, height: height) }
            return Size(width: (height * Float(texture.width) / Float(texture.height)).rounded(), height: height)
        }
    }
}
