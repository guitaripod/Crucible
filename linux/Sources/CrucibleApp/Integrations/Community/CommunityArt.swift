import CrucibleCore
import CrucibleUI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Kiln

/// A Trakt member's face (`TraktAvatarView`): their avatar, or their initials on a gradient of their own until it arrives or
/// when they have none; a VIP wears an accent ring.
@MainActor
final class TraktAvatarView: View {
    private let picture = ArtworkView()
    private var user: TraktUser?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(picture)
    }

    func configure(_ user: TraktUser?) {
        self.user = user
        picture.source = user?.avatarURL.map { .url($0) }
        picture.isHidden = user?.avatarURL == nil
        setNeedsDisplay()
    }

    override var isPointerInteractive: Bool { false }

    override func layoutSubviews() {
        let side = min(frame.width, frame.height)
        picture.frame = Rect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        picture.cornerRadius = side / 2
    }

    override func draw(_ context: inout DrawContext) {
        let side = min(frame.width, frame.height)
        let circle = Rect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        let colors = CastAvatar.gradient(for: user?.username ?? "")
        context.gradient(circle, axis: .diagonal, stops: [(0, Color(hex: colors.start)), (1, Color(hex: colors.end))], radius: side / 2)
        guard let scale = window?.scale, let initials = user?.initials, !initials.isEmpty else { return }
        let layout = TextLayout(initials, font: Font(size: side * 0.38, weight: .bold), scale: scale)
        context.text(layout, at: Point(x: circle.midX - layout.size.width / 2, y: circle.midY - layout.size.height / 2), color: .white)
    }

    override func drawOverlay(_ context: inout DrawContext) {
        guard user?.isVIP == true else { return }
        let side = min(frame.width, frame.height)
        let circle = Rect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        context.stroke(circle, radius: side / 2, width: max(1.5, side / 26), color: Theme.current.palette.accent)
    }
}

/// How Trakt's voters spread their votes from 1 to 10 (`TraktHistogramView`): a bar for each score, the most chosen one in
/// full accent and the others fainter by their share, with 1 and 10 under the ends and a caption under that. The bars
/// rise once when they first show, unless Reduce Motion is on.
@MainActor
final class RatingHistogramView: View {
    private var distribution: TraktRatingDistribution?
    private var rise = Animated(1)

    func show(_ distribution: TraktRatingDistribution, animated: Bool) {
        guard distribution != self.distribution else { return }
        let first = self.distribution == nil
        self.distribution = distribution
        if animated, first {
            rise.reset(0)
            rise.set(1, animation: .timed(duration: 0.7, curve: .easeOut))
            startAnimating()
        }
        setNeedsDisplay()
    }

    private var captionFont: Font { Theme.current.type.footnote }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        return Size(width: min(size.width, metrics.tv(600)), height: metrics.tv(130) + metrics.tv(8) + captionFont.size * 2.6)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = rise.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard let distribution, let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let barArea = metrics.tv(130)
        let gap = barArea / 13
        let width = (frame.width - gap * 9) / 10
        let peak = max(distribution.peakShare, 0.0001)
        let mode = distribution.mode
        for index in 0..<10 {
            let share = distribution.share(of: index + 1)
            let staggered = min(1, max(0, rise.value * 1.4 - Float(index) * 0.04))
            let height = max(3, barArea * Float(share / peak)) * staggered
            let color = index + 1 == mode ? palette.accent : palette.accent.withSRGBAlpha(0.22 + 0.5 * Float(share / peak))
            context.fill(Rect(x: Float(index) * (width + gap), y: barArea - height, width: width, height: height), radius: barArea / 18, color: color)
        }
        let low = TextLayout("1", font: captionFont, scale: scale)
        let high = TextLayout("10", font: captionFont, scale: scale)
        let axisY = barArea + metrics.tv(8)
        context.text(low, at: Point(x: 0, y: axisY), color: palette.labelTertiary)
        context.text(high, at: Point(x: frame.width - high.size.width, y: axisY), color: palette.labelTertiary)
        let caption = TextLayout(TraktCommunityCopy.ratingSpread, font: captionFont, maxWidth: frame.width, alignment: .center, scale: scale)
        context.text(caption, at: Point(x: ((frame.width - caption.size.width) / 2).rounded(), y: axisY + low.size.height), color: palette.labelTertiary)
    }
}

/// A Trakt comment's text as Pango markup (`TraktCommentTextFormatter`): bold, italic, struck and code runs as Trakt's
/// Markdown writes them, links underlined, and inline spoilers as solid bars until revealed.
enum CommentMarkup {
    /// The grey a covered spoiler is drawn in, as a bar over its own letters.
    private static let spoilerBar = "#6E6E73"

    static func markup(_ text: TraktCommentText, revealed: Bool) -> String {
        text.runs.map { run in
            var piece = TextLayout.escapingMarkup(run.text)
            for style in run.styles {
                switch style {
                case .bold: piece = "<b>\(piece)</b>"
                case .italic, .quote: piece = "<i>\(piece)</i>"
                case .strike: piece = "<s>\(piece)</s>"
                case .code: piece = "<tt>\(piece)</tt>"
                case .link: piece = "<u>\(piece)</u>"
                }
            }
            guard run.isSpoiler, !revealed else { return piece }
            return "<span background=\"\(spoilerBar)\" foreground=\"\(spoilerBar)\">\(piece)</span>"
        }.joined()
    }
}

/// A GIF someone attached to a Trakt comment (`TraktGIFView`), played as Trakt plays it, or held on its first frame under
/// Reduce Motion, fitted into the view with a GIF badge. Decoded frames are kept in memory for the recent few.
@MainActor
final class GIFView: View {
    var url: URL? { didSet { if url != oldValue { load() } } }
    var cornerRadius: Float = 0

    private static var decoded: [URL: AnimatedImage] = [:]
    private static var order: [URL] = []
    private static let keep = 12

    private var frames: [Texture] = []
    private var delays: [Double] = []
    private var index = 0
    private var elapsed: Double = 0
    private var loadTask: Task<Void, Never>?

    override var isPointerInteractive: Bool { false }

    override func didMoveToWindow() {
        if frames.isEmpty { load() }
    }

    private func load() {
        loadTask?.cancel()
        frames = []
        delays = []
        index = 0
        elapsed = 0
        setNeedsDisplay()
        guard let url, window != nil else { return }
        if let cached = Self.decoded[url] {
            show(cached)
            return
        }
        loadTask = Task { [weak self] in
            guard let (data, _) = try? await HTTPSession.current.data(from: url), !Task.isCancelled else { return }
            let decoded = await Task.detached { try? AnimatedImage.decodeGIF(data, maximumFrames: 60) }.value
            guard let decoded, !Task.isCancelled, let self, self.url == url else { return }
            Self.remember(decoded, for: url)
            self.show(decoded)
        }
    }

    private static func remember(_ image: AnimatedImage, for url: URL) {
        decoded[url] = image
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > keep { decoded[order.removeFirst()] = nil }
    }

    private func show(_ image: AnimatedImage) {
        guard let gpu = window?.gpu else { return }
        frames = image.frames.compactMap { pixels in
            guard let texture = try? gpu.texture(width: image.width, height: image.height, format: .rgba8, renderable: false) else { return nil }
            _ = pixels.withUnsafeBytes { texture.upload($0.baseAddress!, rowBytes: image.width * 4) }
            return texture
        }
        delays = image.delays
        startAnimating()
        setNeedsDisplay()
    }

    /// The picture's place: as large as fits, centred.
    private func fitted(width: Float, height: Float) -> Rect {
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / width, bounds.height / height)
        let size = Size(width: (width * scale).rounded(), height: (height * scale).rounded())
        return Rect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        guard frames.count > 1, !Animation.reduceMotion, window != nil else { return false }
        elapsed += Double(dt)
        while elapsed >= max(delays[index], 0.02) {
            elapsed -= max(delays[index], 0.02)
            index = (index + 1) % frames.count
        }
        setNeedsDisplay()
        return true
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        guard frames.indices.contains(index) else {
            context.fill(bounds, radius: cornerRadius, color: palette.surfaceRaised)
            return
        }
        let frame = frames[index]
        let picture = fitted(width: Float(frame.width), height: Float(frame.height))
        context.image(frame, in: picture, radius: cornerRadius)
        guard let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        let badge = TextLayout("GIF", font: Theme.current.type.badge, scale: scale)
        let padding = metrics.tv(8)
        let box = Rect(x: picture.minX + metrics.tv(10), y: picture.maxY - badge.size.height - padding - metrics.tv(10),
                       width: badge.size.width + padding * 2, height: badge.size.height + padding)
        context.fill(box, radius: metrics.radiusXS, color: Color.black.withSRGBAlpha(0.6))
        context.text(badge, at: Point(x: box.x + padding, y: box.y + padding / 2), color: .white)
    }
}
