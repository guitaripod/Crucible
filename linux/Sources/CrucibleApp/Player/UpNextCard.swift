import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// Up Next (`TVUpNextViewController`): a glass card over the credits with the next episode's still, its code and title,
/// a countdown when it plays on by itself, Play Now, and Watch Credits (or Close once the episode has ended). After a run
/// of episodes nobody attended it asks "Still watching?" and waits; a sleep timer that stops at the end keeps it from
/// counting.
@MainActor
final class UpNextCard: View {
    let offer: UpNextOffer
    /// Plays the next episode; true when the viewer chose to, false when the countdown ran out.
    var onPlay: ((Bool) -> Void)?
    var onLeave: (() -> Void)?

    private let artwork = ArtworkView()
    private let play: ButtonView
    private let leave: ButtonView
    private var remaining: Float
    private var counting: Bool
    private let asksStillWatching: Bool
    private var appear = Animated(0)
    private var tone = GlassTone()
    /// The text column's tone: the card's, or dark where glare in the picture lies right under the text.
    private var textTone = GlassTone()

    init(offer: UpNextOffer, asksStillWatching: Bool = false, stopsAfterItem: Bool = false) {
        self.offer = offer
        self.asksStillWatching = asksStillWatching
        counting = offer.autoplays && !asksStillWatching && !stopsAfterItem
        remaining = Float(UpNextOffer.countdownSeconds)
        play = ButtonView(style: .primary, title: UpNextText.playTitle(asksStillWatching: asksStillWatching), symbol: "play.fill")
        leave = ButtonView(style: .glass, title: UpNextText.leaveTitle(keepsCreditsPlaying: !offer.playbackEnded))
        super.init()
        artwork.source = (offer.episode.thumb ?? offer.episode.art).map { .path($0, .backdrop) }
        artwork.cornerRadius = Theme.current.metrics.radiusS
        play.onPress = { [weak self] in self?.onPlay?(true) }
        leave.onPress = { [weak self] in self?.onLeave?() }
        [artwork, play, leave].forEach(addSubview)
    }

    override var preferredFocusView: View? { play }
    override var remembersFocus: Bool { true }
    override var overdraw: Float { Theme.current.metrics.tv(60) }

    func appearNow() {
        appear.set(1, animation: .spring(response: 0.4, dampingFraction: 0.85))
        startAnimating()
    }

    /// Stops the countdown (the viewer moved or chose to watch the credits).
    func stopCounting() {
        counting = false
        setNeedsDisplay()
    }

    private var cardWidth: Float { Theme.current.metrics.tv(900) }
    private var inset: Float { Theme.current.metrics.tv(28) }
    private var thumbSize: Size {
        let width = (cardWidth * 0.4).rounded()
        return Size(width: width, height: (width * 9 / 16).rounded())
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        return Size(width: cardWidth, height: inset * 2 + thumbSize.height + metrics.tv(24) + metrics.primaryControlHeight)
    }

    /// The still and its text side by side, the two buttons in a row under them.
    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        artwork.frame = Rect(origin: Point(x: inset, y: inset), size: thumbSize)
        let playSize = play.sizeThatFits(Size(width: 400, height: 200))
        let leaveSize = leave.sizeThatFits(Size(width: 400, height: 200))
        let y = artwork.frame.maxY + metrics.tv(24)
        play.frame = Rect(x: inset, y: y, width: playSize.width, height: playSize.height)
        leave.frame = Rect(x: play.frame.maxX + metrics.tv(20), y: y, width: leaveSize.width, height: leaveSize.height)
    }

    override func drawOverlay(_ context: inout DrawContext) {
        guard counting else { return }
        let metrics = Theme.current.metrics
        let total = Float(UpNextOffer.countdownSeconds)
        let progress = 1 - max(remaining, 0) / max(total, 1)
        let bar = Rect(x: artwork.frame.minX + metrics.tv(14), y: artwork.frame.maxY - metrics.tv(22), width: artwork.frame.width - metrics.tv(28),
                       height: metrics.progressBarThickness)
        ProgressBarStyle.draw(progress: progress, in: bar, onArt: true, context: &context)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        var moving = [appear.advance(dt), tone.advance(dt), textTone.advance(dt)].contains(true)
        alpha = appear.value
        translation = Point(x: (1 - appear.value) * Theme.current.metrics.tv(60), y: 0)
        if counting {
            remaining -= dt
            moving = true
            if remaining <= 0 {
                counting = false
                onPlay?(false)
            }
        }
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        if tone.update(context, rect: bounds) { startAnimating() }
        GlassStyle.capsule(in: bounds, radius: metrics.radiusL, light: Point(x: bounds.midX, y: bounds.minY - bounds.height), floating: true,
                           tone: tone.value, context: &context)
        let x = artwork.frame.maxX + metrics.tv(28)
        let width = bounds.width - x - metrics.tv(28)
        if textTone.update(context, rect: Rect(x: x, y: 0, width: width, height: artwork.frame.maxY), on: tone) { startAnimating() }
        let label = GlassStyle.label(tone: textTone.value)
        let secondary = GlassStyle.secondaryLabel(tone: textTone.value)
        var y = metrics.tv(30)
        let eyebrow = TextLayout(UpNextText.eyebrow(asksStillWatching: asksStillWatching), font: theme.type.eyebrow, maxWidth: width, scale: scale)
        context.text(eyebrow, at: Point(x: x, y: y), color: theme.palette.accentText)
        y += eyebrow.size.height + metrics.tv(6)
        let title = TextLayout(offer.episode.title, font: theme.type.cardTitle, maxWidth: width, maxLines: 2, scale: scale)
        context.text(title, at: Point(x: x, y: y), color: label)
        y += title.size.height + metrics.tv(4)
        let code = DetailFormat.episodeCode(season: offer.episode.parentIndex, episode: offer.episode.index)
        let line = UpNextText.secondary(code: code, remaining: max(Int(remaining.rounded(.up)), 0), counting: counting, isEpisode: code != nil)
        let detail = TextLayout(line, font: theme.type.cardSubtitle, maxWidth: width, scale: scale)
        context.text(detail, at: Point(x: x, y: y), color: secondary)
    }
}
