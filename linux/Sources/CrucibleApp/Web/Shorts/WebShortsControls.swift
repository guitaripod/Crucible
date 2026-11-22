import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// A round glass button of the Shorts player with what it does written under it: lit while what it stands for is on (a
/// clip saved for later, the sound muted), lifted under the pointer, turned into the light pill by keyboard focus, and
/// popping as its state turns on.
@MainActor
final class WebShortsRoundButton: View {
    var symbol: Symbol { didSet { if symbol != oldValue { setNeedsDisplay() } } }
    var caption: String? { didSet { if caption != oldValue { setNeedsDisplay() } } }
    /// The name a tooltip and a screen reader give it.
    var name: String
    var shortcut: String?
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            lit.set(isOn ? 1 : 0, animation: .fade)
            if isOn {
                pop.reset(0.72)
                pop.set(1, animation: .spring(response: 0.36, dampingFraction: 0.42))
            }
            startAnimating()
        }
    }
    var onPress: (() -> Void)?
    /// The wheel turned over the button, in notches toward the viewer (the sound button's volume).
    var onWheel: ((Float) -> Void)?

    private var lift = Animated(0)
    private var focus = Animated(0)
    private var press = Animated(0)
    private var lit = Animated(0)
    private var pop = Animated(1)
    private var tone = GlassTone()
    private var pressedByPointer = false

    init(symbol: Symbol, name: String, caption: String? = nil, shortcut: String? = nil) {
        self.symbol = symbol
        self.name = name
        self.caption = caption
        self.shortcut = shortcut
        super.init()
    }

    /// The circle's diameter and the whole button's size with its caption, in the current layout.
    static var diameter: Float { Theme.current.metrics.tv(Theme.current.density == .desk ? 92 : 84) }
    static var captionHeight: Float { Theme.current.metrics.tv(40) }
    static var size: Size { Size(width: diameter + Theme.current.metrics.tv(56), height: diameter + captionHeight) }

    override var canBecomeFocused: Bool { true }
    override var accessibilityLabel: String? { name }
    override var accessibilityIsSelected: Bool? { isOn ? true : nil }
    override var overdraw: Float { Theme.current.metrics.tv(40) }

    override func tooltip(at point: Point) -> String? {
        shortcut.map { "\(name) (\($0))" } ?? name
    }

    private var circle: Rect {
        let diameter = Self.diameter
        return Rect(x: ((bounds.width - diameter) / 2).rounded(), y: 0, width: diameter, height: diameter)
    }

    private func updateLift() {
        let focused = isFocused && (window?.isFocusVisible ?? false)
        lift.set(focused || isHovered ? 1 : 0, animation: .focus)
        focus.set(focused ? 1 : 0, animation: .focus)
        startAnimating()
    }

    override func focusDidChange(focused: Bool, animated: Bool) { updateLift() }
    override func focusVisibilityDidChange(_ visible: Bool) { if isFocused { updateLift() } }
    override func pointerEntered() { updateLift() }

    override func pointerExited() {
        pressedByPointer = false
        press.set(0, animation: .press)
        updateLift()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        pressedByPointer = true
        press.set(1, animation: .press)
        startAnimating()
        return true
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary else { return }
        press.set(0, animation: .press)
        startAnimating()
        if pressedByPointer && inside { onPress?() }
        pressedByPointer = false
    }

    override func scrolled(_ event: ScrollEvent) -> Bool {
        guard let onWheel else { return false }
        let notches = event.isDiscrete ? event.notchesY : event.dy / 40
        if notches != 0 { onWheel(-notches) }
        return true
    }

    override func activate() {
        press.reset(1)
        press.set(0, animation: .press)
        startAnimating()
        onPress?()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [lift.advance(dt), focus.advance(dt), press.advance(dt), lit.advance(dt), pop.advance(dt), tone.advance(dt)].contains(true)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let palette = theme.palette
        let rect = circle
        let size = (1 + 0.06 * lift.value) * (1 - 0.06 * press.value) * pop.value
        context.transformed(scale: size, about: rect.center) { drawn in
            if tone.update(drawn, rect: rect) { startAnimating() }
            GlassStyle.capsule(in: rect, light: Point(x: rect.midX, y: rect.minY - rect.height), press: press.value + 0.4 * lift.value, floating: true,
                               tone: tone.value, context: &drawn)
            if lit.value > 0.01 { drawn.fill(rect, radius: rect.height / 2, color: palette.accent.withAlpha(lit.value)) }
            if focus.value > 0.01 { drawn.fill(rect, radius: rect.height / 2, color: palette.focusFill.withAlpha(focus.value)) }
            let resting = GlassStyle.label(tone: tone.value).mixed(with: palette.onAccent, amount: lit.value)
            let glyph = rect.height * 0.42
            drawn.symbol(symbol, in: Rect(x: rect.midX - glyph / 2, y: rect.midY - glyph / 2, width: glyph, height: glyph),
                         color: resting.mixed(with: palette.onFocusFill, amount: focus.value))
        }
        guard let caption, !caption.isEmpty else { return }
        let text = TextLayout(caption, font: theme.type.footnote, maxWidth: bounds.width, maxLines: 1, alignment: .center, scale: scale)
        let x = ((bounds.width - text.size.width) / 2 * scale).rounded() / scale
        context.text(text, at: Point(x: x, y: rect.maxY + metrics.tv(8)), color: palette.onArt.withAlpha(0.82 + 0.18 * lift.value))
    }
}

/// The Shorts player's actions down the side of the clip: Watch Later, Comments, Copy Link, the channel, the sound and
/// More. Focus arriving from the clip lands on the one it left from.
@MainActor
final class WebShortsRail: View {
    let later = WebShortsRoundButton(symbol: "bookmark", name: WebCopy.watchLater, shortcut: "S")
    let comments = WebShortsRoundButton(symbol: "bubble.left", name: WebShortsCopy.comments, shortcut: "C")
    let link = WebShortsRoundButton(symbol: "link", name: WebShortsCopy.copyLink, shortcut: KeyName.chord(KeyName.ctrl, "C"))
    let channel = WebShortsRoundButton(symbol: "person.crop.circle", name: WebShortsCopy.goToChannel, shortcut: "O")
    let sound = WebShortsRoundButton(symbol: "speaker.wave.2", name: AppCommandCopy.mute, shortcut: "M")
    let more = WebShortsRoundButton(symbol: "ellipsis", name: WebShortsCopy.more)

    var buttons: [WebShortsRoundButton] { [later, comments, link, channel, sound, more] }

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        buttons.forEach(addSubview)
    }

    override var remembersFocus: Bool { true }
    override var preferredFocusView: View? { later }

    private static var spacing: Float { Theme.current.metrics.tv(14) }

    /// The rail's size for `count` buttons.
    static func size(count: Int = 6) -> Size {
        let button = WebShortsRoundButton.size
        return Size(width: button.width, height: Float(count) * button.height + Float(count - 1) * spacing)
    }

    override func layoutSubviews() {
        let size = WebShortsRoundButton.size
        var y: Float = 0
        for button in buttons {
            button.frame = Rect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height + Self.spacing
        }
    }
}

/// The words the Shorts player's own controls use.
enum WebShortsCopy {
    static let title = String(localized: "Shorts", comment: "Channel page tab: short vertical clips")
    static let comments = String(localized: "Comments", comment: "Section of a web video's page")
    static let copyLink = String(localized: "Copy Link", comment: "Web video menu")
    static let goToChannel = String(localized: "Go to Channel", comment: "Web video menu")
    static let more = String(localized: "More")
    static let channelCaption = String(localized: "Channel", comment: "Shorts player: caption under the button that opens the clip's channel")
    static let saved = String(localized: "Saved", comment: "Shorts player: caption under the Watch Later button once the clip is saved")
    static let save = String(localized: "Save", comment: "Shorts player: caption under the button that saves the clip to Watch Later")
    static let share = String(localized: "Share", comment: "Shorts player: caption under the button that copies the clip's link")
    static let sound = String(localized: "Sound", comment: "Shorts player: caption under the button that mutes the sound")
    static let muted = String(localized: "Muted", comment: "Shorts player: caption under the sound button while the sound is off")
    static let linkCopied = String(localized: "Link Copied", comment: "Shorts player message after copying the clip's link")
    static let savedForLater = String(localized: "Saved to Watch Later", comment: "Shorts player message after saving the clip")
    static let removedFromLater = String(localized: "Removed from Watch Later", comment: "Shorts player message after taking the clip out of Watch Later")
    static let playNext = String(localized: "Play Next Automatically", comment: "Shorts player menu: move on to the next clip when one ends, instead of repeating it")
    static let playsNext = String(localized: "Plays the Next Clip", comment: "Shorts player message: clips now follow one another on their own")
    static let repeats = String(localized: "Repeats This Clip", comment: "Shorts player message: a clip now repeats until the viewer moves on")
    static let openInPlayer = String(localized: "Open in the Player", comment: "Shorts player menu: watch the clip in the full player, with its quality, subtitles and speed")
    static let lastOne = String(localized: "That’s the Last One", comment: "Shorts player message at the end of the feed")
    static let previous = String(localized: "Previous Short", comment: "Shorts player: button and shortcut that go to the clip before")
    static let next = String(localized: "Next Short", comment: "Shorts player: button and shortcut that go to the clip after")
    static let details = String(localized: "Description and Comments", comment: "Shorts player: shortcut and panel showing the clip's description and its top comments")
    static let fromYourChannels = String(localized: "From Your Channels", comment: "Shorts player: where the clips come from when they are the followed channels' newest")
    static let followed = String(localized: "Following", comment: "Button on a followed channel's page; pressing it unfollows")
    static let follow = String(localized: "Follow", comment: "Button that follows a channel")
    static let retry = String(localized: "Retry")
    static let seek = String(localized: "Back or Ahead Five Seconds", comment: "Shorts shortcut list: J and L move through the clip")

    static func volume(_ percent: Int) -> String {
        String(localized: "Volume \(percent)%", comment: "Shorts player message after changing the volume, as in \"Volume 80%\"")
    }

    static func likes(_ count: Int) -> String {
        String(localized: "\(Formatters.compactCount(count)) likes", comment: "How many liked a web video, as in \"93K likes\"")
    }
}
