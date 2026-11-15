import Foundation
import Kiln

/// The hexagonal crystal of the app icon (`CrystalGlyphView`): a body washed from light orange at the top to deep ember at
/// the bottom, luminous edges, X-and-spine facets and a hot core over a soft ambient glow. While shown it breathes (the
/// glow and the core swell and settle), unless Reduce Motion is on; `flare` ignites it for the hand-off to the app.
@MainActor
public final class CrystalGlyphView: View {
    private static let outline: [Point] = [
        Point(x: 0.5, y: 0.14), Point(x: 0.707, y: 0.41), Point(x: 0.707, y: 0.59),
        Point(x: 0.5, y: 0.86), Point(x: 0.293, y: 0.59), Point(x: 0.293, y: 0.41),
    ]

    private var breath: Float = 0
    private var isBreathing = false
    private var dim = Animated(0)
    private var flareAmount = Animated(0)
    private var onFlared: (() -> Void)?

    public init() {
        super.init()
    }

    public override func didMoveToWindow() {
        if isBreathing { startAnimating() }
    }

    public func startBreathing() {
        guard !isBreathing else { return }
        isBreathing = true
        startAnimating()
    }

    public func stopBreathing() {
        isBreathing = false
        setNeedsDisplay()
    }

    /// Dims the crystal behind a failure, and stops its breathing.
    public func setDimmed(_ dimmed: Bool) {
        dim.set(dimmed ? 1 : 0, animation: .timed(duration: 0.35, curve: .easeInOut))
        if dimmed { stopBreathing() } else { startBreathing() }
        startAnimating()
    }

    /// Ignites the crystal (the glow and core swell, the edges blaze) and calls `completion` once it has, or at once under
    /// Reduce Motion.
    public func flare(completion: @escaping () -> Void) {
        stopBreathing()
        guard !Animation.reduceMotion, window != nil else { return completion() }
        onFlared = completion
        flareAmount.set(1, animation: .timed(duration: 0.45, curve: .easeOut))
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [dim.advance(dt), flareAmount.advance(dt)].contains(true)
        if !moving, let done = onFlared, flareAmount.value >= 1 {
            onFlared = nil
            done()
        }
        let breathes = isBreathing && !Animation.reduceMotion && window != nil
        if breathes { breath = (breath + dt / 3.6).truncatingRemainder(dividingBy: 1) }
        setNeedsDisplay()
        return moving || breathes
    }

    public override var overdraw: Float { min(frame.width, frame.height) * 0.6 }

    public override func draw(_ context: inout DrawContext) {
        let side = min(frame.width, frame.height)
        guard side > 0 else { return }
        let box = Rect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        let points = Self.outline.map { Point(x: box.minX + $0.x * side, y: box.minY + $0.y * side) }
        let center = Point(x: box.midX, y: box.midY)
        let wave = isBreathing && !Animation.reduceMotion ? (1 - cos(breath * 2 * .pi)) / 2 : 1
        let dimming = dim.value
        let flare = flareAmount.value

        let ambient = (0.55 + 0.45 * wave) * (1 - 0.75 * dimming) * (1 + 0.35 * flare)
        let glowBox = box.insetBy(-side * 0.6, -side * 0.6)
        context.glow(in: glowBox, radius: 0, center: center, glowRadius: side * (0.62 + 0.25 * flare),
                     color: Color(srgbRed: 1, green: 0.45, blue: 0.05).withSRGBAlpha(min(1, 0.55 * ambient)))

        var hexagon = Path()
        hexagon.move(to: points[0])
        points.dropFirst().forEach { hexagon.line(to: $0) }
        hexagon.close()
        let bodyAlpha = 1 - 0.3 * dimming
        context.faded(bodyAlpha) { body in
            var base = hexagon
            base.fill()
            body.shape(base, in: bounds, color: Color(srgbRed: 0.55, green: 0.24, blue: 0.06))
            var middle = hexagon
            middle.fillRamp(fromY: box.minY + side * 0.14, coverage: 1, toY: box.minY + side * 0.86, toCoverage: 0)
            body.shape(middle, in: bounds, color: Color(srgbRed: 0.93, green: 0.45, blue: 0.10))
            var top = hexagon
            top.fillRamp(fromY: box.minY + side * 0.14, coverage: 1, toY: box.minY + side * 0.5, toCoverage: 0)
            body.shape(top, in: bounds, color: Color(srgbRed: 1.0, green: 0.62, blue: 0.25))
        }

        var facets = Path()
        for (from, to) in [(0, 3), (5, 2), (1, 4)] {
            facets.move(to: points[from])
            facets.line(to: points[to])
        }
        facets.stroke(width: max(1, side / 300), coverage: 0.55)
        context.shape(facets, in: bounds, color: Color(srgbRed: 1, green: 0.85, blue: 0.62))

        var halo = hexagon
        halo.stroke(width: side * (0.04 + 0.05 * flare), coverage: 0.22 + 0.25 * flare)
        context.shape(halo, in: bounds, color: Color(srgbRed: 1, green: 0.6, blue: 0.2))
        var edges = hexagon
        edges.stroke(width: max(1.5, side / 150))
        context.shape(edges, in: bounds, color: Color(srgbRed: 1, green: 0.78, blue: 0.48))

        let swell = (isBreathing && !Animation.reduceMotion ? 0.92 + 0.16 * wave : 1) * (1 + 0.6 * flare)
        let core = side * 0.17 * swell
        let coreAlpha = 1 - 0.5 * dimming
        context.glow(in: Rect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2), radius: core, center: center, glowRadius: core * 1.15,
                     color: Color(srgbRed: 1, green: 0.4, blue: 0).withSRGBAlpha(0.85 * coreAlpha))
        context.glow(in: Rect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2), radius: core, center: center, glowRadius: core * 0.6,
                     color: Color(srgbRed: 1, green: 0.78, blue: 0.35).withAlpha(coreAlpha))
        context.glow(in: Rect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2), radius: core, center: center, glowRadius: core * 0.26,
                     color: Color.white.withAlpha(coreAlpha))
    }
}
