import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import MidgarCore
@preconcurrency import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Shows what is at the moment the viewer scrubs to, above the system player's scrubber, the instant they point at it.
///
/// The system player has no scrub preview on iPhone and iPad and no way to give it one, and while a finger drags its
/// scrubber over a stream the picture behind can only follow as fast as the network hands over each new place. So the
/// preview does not wait for the player: it reads the scrubber, which is a `UISlider`, and shows the still for where it
/// points from `ScrubStillSource`, which holds them ahead of the scrub. A finger or a trackpad drag on the scrubber
/// brings the card up over the thumb; a pointer resting on the scrubber brings it up over the pointer.
@MainActor
final class ScrubPreview: NSObject, UIGestureRecognizerDelegate {
    /// The moment a place along the scrubber stands for (0 at its start, 1 at its end), or nil when the player has nothing
    /// with a length in it.
    var moment: (@MainActor (Double) -> Moment?)?
    /// The name of the chapter a moment falls in.
    var chapterTitle: (@MainActor (Double) -> String?)?
    /// Called when a scrub begins, and when it ends with the moment it ended on.
    var onScrubbing: (@MainActor (Bool, Double?) -> Void)?
    var stills: ScrubStillSource? {
        didSet {
            oldValue?.onChange = nil
            stills?.onChange = { [weak self] in self?.stillArrived() }
        }
    }

    /// A moment as the scrubber's own clock reads it, which is what the card says beside the system's times, and on the
    /// title's timeline, where its still and chapter are. The two differ on a stream that starts partway into its title.
    struct Moment {
        let clock: Double
        let title: Double
    }

    /// How far above and below the scrubber a pointer still counts as on it.
    private static let hoverReach: CGFloat = 16
    private static let gapAboveScrubber: CGFloat = Glass.isAvailable ? 30 : 16
    private static let edgeMargin: CGFloat = 8
    /// The least of the player's width its scrubber takes up, on any device in any shape.
    private static let narrowestScrubber: CGFloat = 0.4

    private weak var host: UIView?
    private weak var slider: UISlider?
    private let card = ScrubPreviewCard()
    private let touches = TouchWatch()
    private let hover = UIHoverGestureRecognizer()
    private var cardCenter: NSLayoutConstraint?
    private var cardBottom: NSLayoutConstraint?
    private var link: CADisplayLink?
    private var valueChanged: UIAction?
    private var viewerMovedSlider = false
    private var isScrubbing = false
    private var pointed: (place: Double, x: CGFloat)?
    private var chapter: String?
    private var tally = Tally()
    #if DEBUG
    private var sweep: (from: Float, to: Float, began: CFTimeInterval, lasts: CFTimeInterval)?
    private var sweepSeek: (@MainActor (Double) -> Void)?
    #endif

    /// What one scrub showed, for the log.
    private struct Tally {
        var began = ContinuousClock.now
        var moves = 0
        var exact = 0
        var standIns = 0
        var blank = 0
    }

    init(playerController: AVPlayerViewController) {
        super.init()
        guard let host = playerController.view else { return }
        self.host = host
        touches.onChange = { [weak self] in self?.touchesChanged() }
        touches.delegate = self
        host.addGestureRecognizer(touches)
        hover.addTarget(self, action: #selector(pointerMoved))
        hover.delegate = self
        host.addGestureRecognizer(hover)
        installCard(in: host)
    }

    func remove() {
        endScrub()
        stopLink()
        stills = nil
        if let valueChanged { slider?.removeAction(valueChanged, for: .valueChanged) }
        touches.view?.removeGestureRecognizer(touches)
        hover.view?.removeGestureRecognizer(hover)
        card.removeFromSuperview()
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// The card sits on top of the player, pinned by its bottom edge and its middle, and never leaves the safe area: at
    /// either end of the scrubber it stops at the edge while the thumb goes on.
    private func installCard(in host: UIView) {
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        let center = card.centerXAnchor.constraint(equalTo: host.leadingAnchor)
        center.priority = .defaultHigh
        let bottom = card.bottomAnchor.constraint(equalTo: host.topAnchor)
        NSLayoutConstraint.activate([
            center,
            bottom,
            card.leadingAnchor.constraint(greaterThanOrEqualTo: host.safeAreaLayoutGuide.leadingAnchor, constant: Self.edgeMargin),
            card.trailingAnchor.constraint(lessThanOrEqualTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -Self.edgeMargin),
        ])
        cardCenter = center
        cardBottom = bottom
    }

    // MARK: - The system scrubber

    /// The system player's scrubber: the widest slider in it, and one that spans most of the player (the other is its
    /// volume, which never does). It is made with the controls, so it is looked for again whenever the one found before
    /// has gone.
    private func timeline() -> UISlider? {
        if let slider, slider.window != nil { return slider }
        guard let host else { return nil }
        let found = Self.sliders(in: host).max { $0.bounds.width < $1.bounds.width }
        guard let found, found.bounds.width >= host.bounds.width * Self.narrowestScrubber else { return nil }
        let action = UIAction { [weak self] _ in self?.viewerMovedSlider = true }
        found.addAction(action, for: .valueChanged)
        valueChanged = action
        slider = found
        return found
    }

    private static func sliders(in view: UIView) -> [UISlider] {
        view.subviews.flatMap { [$0 as? UISlider].compactMap { $0 } + sliders(in: $0) }
    }

    /// Whether the scrubber is on screen: it stays in the player, faded out, while the controls are hidden.
    private static func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let view = current {
            if view.isHidden || view.alpha < 0.05 { return false }
            current = view.superview
        }
        return true
    }

    /// Where along itself the scrubber points, from 0 to 1.
    private static func place(of slider: UISlider) -> Double {
        let span = slider.maximumValue - slider.minimumValue
        return span > 0 ? Double((slider.value - slider.minimumValue) / span) : 0
    }

    /// The scrubber's track in the host's coordinates, and whether it runs from right to left.
    private func track(of slider: UISlider) -> (frame: CGRect, isMirrored: Bool)? {
        guard let host else { return nil }
        let frame = slider.convert(slider.trackRect(forBounds: slider.bounds), to: host)
        guard frame.width > 0 else { return nil }
        return (frame, UIView.userInterfaceLayoutDirection(for: slider.semanticContentAttribute) == .rightToLeft)
    }

    // MARK: - A finger or a drag

    private func touchesChanged() {
        if touches.isDown {
            viewerMovedSlider = false
            _ = timeline()
            startLink()
        } else {
            stopLink()
            endScrub()
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// Once a frame while a finger is down: a scrub begins the moment the scrubber is being dragged or says the viewer
    /// moved it, and from then on the card follows the thumb. Where the scrubber points is no sign of a scrub by itself:
    /// the system player lets it fall behind while its controls are hidden and catches it up on the tap that shows them.
    @objc private func frame() {
        guard let slider = timeline() else { return }
        #if DEBUG
        guard advanceSweep(on: slider) else { return }
        #endif
        if !isScrubbing {
            guard slider.isTracking || viewerMovedSlider else { return }
            beginScrub()
        }
        guard let track = track(of: slider) else { return }
        let place = Self.place(of: slider)
        let along = track.isMirrored ? 1 - place : place
        let still = point(at: place, x: track.frame.minX + track.frame.width * along, above: track.frame.minY)
        tally.moves += 1
        switch still?.isExact {
        case true?: tally.exact += 1
        case false?: tally.standIns += 1
        case nil: tally.blank += 1
        }
    }

    private func beginScrub() {
        isScrubbing = true
        chapter = nil
        tally = Tally()
        onScrubbing?(true, nil)
        raiseCard()
    }

    private func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        viewerMovedSlider = false
        let landing = pointed.flatMap { moment?($0.place) }
        pointed = nil
        onScrubbing?(false, landing?.title)
        card.setShown(false)
        let took = ContinuousClock.now - tally.began
        let milliseconds = Int(took.components.seconds) * 1000 + Int(took.components.attoseconds / 1_000_000_000_000_000)
        MidgarLog.info("Scrub to \(landing.map { Formatters.timestamp($0.title) } ?? "nowhere") in \(milliseconds) ms: \(tally.moves) frames, stills \(tally.exact) exact, \(tally.standIns) standing in, \(tally.blank) missing", category: .playback)
    }

    // MARK: - A pointer

    @objc private func pointerMoved() {
        let isOver = hover.state == .began || hover.state == .changed
        pointer(at: isOver ? host.map { hover.location(in: $0) } : nil)
    }

    /// The pointer is at `location` in the player, or gone: resting on the scrubber while it is on screen, it gets the
    /// card for the moment under it. A scrub under way keeps the card to itself.
    private func pointer(at location: CGPoint?) {
        guard !isScrubbing, !touches.isDown else { return }
        guard let location, let slider = timeline(), Self.isVisible(slider), let track = track(of: slider),
              track.frame.insetBy(dx: 0, dy: -Self.hoverReach).contains(location) else {
            guard pointed != nil else { return }
            pointed = nil
            card.setShown(false)
            return
        }
        let along = Double((location.x - track.frame.minX) / track.frame.width)
        raiseCard()
        point(at: track.isMirrored ? 1 - along : along, x: location.x, above: track.frame.minY)
    }

    // MARK: - The card

    /// Shows the card, above whatever the system player has put on screen since the card was made.
    private func raiseCard() {
        guard !card.isShown else { return }
        host?.bringSubviewToFront(card)
        card.setShown(true)
    }

    /// Fills the card for `place` along the scrubber and stands it over `x`, above the scrubber's top edge at `top`.
    /// Returns the still it showed.
    @discardableResult
    private func point(at place: Double, x: CGFloat, above top: CGFloat) -> ScrubStill? {
        guard let host, let moment = moment?(min(max(place, 0), 1)) else { return nil }
        pointed = (place, x)
        let still = stills?.still(at: moment.title)
        let name = chapterTitle?(moment.title)
        card.show(
            time: Formatters.timestamp(moment.clock),
            chapter: name,
            still: still?.image,
            hasPicture: stills?.offersStills == true,
            pictureWidth: Self.pictureWidth(in: host)
        )
        cardCenter?.constant = x
        cardBottom?.constant = top - Self.gapAboveScrubber
        if isScrubbing, let chapter, let name, name != chapter { Haptics.selection() }
        if isScrubbing, name != nil { chapter = name }
        return still
    }

    /// A still landed: the card shows it if it is still pointing somewhere.
    private func stillArrived() {
        guard card.isShown, let pointed, let slider, let track = track(of: slider) else { return }
        point(at: pointed.place, x: pointed.x, above: track.frame.minY)
    }

    /// Half the short side of the player, between a width a phone held upright has room for and one that stays a preview
    /// on an iPad.
    private static func pictureWidth(in host: UIView) -> CGFloat {
        min(max((min(host.bounds.width, host.bounds.height) * 0.5).rounded(), 168), 256)
    }
}

#if DEBUG
extension ScrubPreview {
    /// Scrubs with no finger on the device, for a debug walk on a real iPhone: the scrubber is moved from one place along
    /// itself to another over `seconds`, and told it was moved, each frame, the way a drag moves it. The system player
    /// only seeks for a real finger, so `seek` is handed each place to move the player as the system player would.
    func debugScrub(from: Double, to: Double, over seconds: TimeInterval, seek: @escaping @MainActor (Double) -> Void) -> Bool {
        guard sweep == nil, let slider = timeline() else { return false }
        let span = slider.maximumValue - slider.minimumValue
        sweep = (slider.minimumValue + Float(from) * span, slider.minimumValue + Float(to) * span, CACurrentMediaTime(), max(seconds, 0.1))
        sweepSeek = seek
        startLink()
        return true
    }

    /// Rests a pointer on the scrubber at `place` along it, for a debug walk; false when the scrubber is not on screen.
    func debugPoint(at place: Double) -> Bool {
        guard let slider = timeline(), let track = track(of: slider) else { return false }
        pointer(at: CGPoint(x: track.frame.minX + track.frame.width * place, y: track.frame.midY))
        return pointed != nil
    }

    /// Moves the scrubber along a sweep under way; false once the sweep has just ended, which ends the scrub as lifting
    /// the finger does.
    private func advanceSweep(on slider: UISlider) -> Bool {
        guard let sweep else { return true }
        let progress = Float(min((CACurrentMediaTime() - sweep.began) / sweep.lasts, 1))
        slider.setValue(sweep.from + (sweep.to - sweep.from) * progress, animated: false)
        slider.sendActions(for: .valueChanged)
        sweepSeek?(Self.place(of: slider))
        guard progress >= 1 else { return true }
        self.sweep = nil
        sweepSeek = nil
        stopLink()
        endScrub()
        return false
    }
}
#endif

/// Knows whether a finger (or a pressed pointer) is down anywhere on the player, and nothing else: it never recognizes,
/// so every touch goes on to the system player's own controls untouched.
private final class TouchWatch: UIGestureRecognizer {
    var onChange: (() -> Void)?
    private var down = 0
    var isDown: Bool { down > 0 }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        count(touches.count)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        count(-touches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        count(-touches.count)
    }

    override func reset() {
        super.reset()
        guard down != 0 else { return }
        down = 0
        onChange?()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    private func count(_ change: Int) {
        let wasDown = isDown
        down = max(0, down + change)
        if isDown != wasDown { onChange?() }
    }
}
