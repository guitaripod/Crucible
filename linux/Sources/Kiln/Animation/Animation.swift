import Foundation

/// How a value moves to a new target: a spring (focus lift, parallax, scrolling into place) or a timed curve with the
/// tvOS durations (fades, backdrops).
public enum Animation: Sendable, Equatable {
    case spring(response: Float, dampingFraction: Float)
    case timed(duration: Float, curve: Curve)

    public enum Curve: Sendable, Equatable {
        case linear, easeIn, easeOut, easeInOut

        /// The cubic Bézier timing functions Core Animation names, solved for y at x = `t`.
        public func value(at t: Float) -> Float {
            let x = min(max(t, 0), 1)
            switch self {
            case .linear: return x
            case .easeIn: return Self.bezier(x, 0.42, 0, 1, 1)
            case .easeOut: return Self.bezier(x, 0, 0, 0.58, 1)
            case .easeInOut: return Self.bezier(x, 0.42, 0, 0.58, 1)
            }
        }

        private static func bezier(_ x: Float, _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> Float {
            func sample(_ t: Float, _ a1: Float, _ a2: Float) -> Float {
                let c = 3 * a1
                let b = 3 * (a2 - a1) - c
                let a = 1 - c - b
                return ((a * t + b) * t + c) * t
            }
            func slope(_ t: Float, _ a1: Float, _ a2: Float) -> Float {
                let c = 3 * a1
                let b = 3 * (a2 - a1) - c
                let a = 1 - c - b
                return (3 * a * t + 2 * b) * t + c
            }
            var t = x
            for _ in 0..<8 {
                let error = sample(t, x1, x2) - x
                let derivative = slope(t, x1, x2)
                if abs(error) < 1e-5 || abs(derivative) < 1e-6 { break }
                t -= error / derivative
            }
            t = min(max(t, 0), 1)
            return sample(t, y1, y2)
        }
    }

    /// The focus lift and anything that follows the hand: quick, barely overshooting.
    public static let focus = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Content scrolling to reveal what gained focus.
    public static let scroll = Animation.spring(response: 0.42, dampingFraction: 1)
    public static let fade = Animation.timed(duration: 0.25, curve: .easeInOut)
    public static let backdrop = Animation.timed(duration: 0.35, curve: .easeInOut)
    public static let press = Animation.timed(duration: 0.12, curve: .easeOut)

    /// Reduce Motion: the desktop's "animation speed" set to instant, read through the settings portal. Movement
    /// collapses to its end state; fades stay, shortened, as `TVMotion` keeps them.
    nonisolated(unsafe) public static var reduceMotion = false
}

/// A value that animates toward its target, advanced by the window each frame.
public struct Animated: Sendable {
    public private(set) var value: Float
    public private(set) var target: Float
    private var velocity: Float = 0
    private var animation: Animation?
    private var start: Float = 0
    private var elapsed: Float = 0

    public init(_ value: Float) {
        self.value = value
        target = value
    }

    public var isAnimating: Bool { animation != nil }

    /// Moves to `target` with `animation`, or at once without one. A spring keeps the velocity it has, so a new target
    /// mid-flight bends the motion instead of restarting it.
    public mutating func set(_ newTarget: Float, animation newAnimation: Animation?) {
        guard newTarget != target || (newAnimation == nil && value != newTarget) else { return }
        target = newTarget
        guard var chosen = newAnimation else {
            value = newTarget
            velocity = 0
            animation = nil
            return
        }
        if Animation.reduceMotion {
            if case .timed(let duration, let curve) = chosen, duration > 0 {
                chosen = .timed(duration: min(duration, 0.15), curve: curve)
            } else {
                value = newTarget
                velocity = 0
                animation = nil
                return
            }
        }
        if case .timed = chosen { velocity = 0 }
        animation = chosen
        start = value
        elapsed = 0
    }

    /// Jumps to `value` and stops.
    public mutating func reset(_ newValue: Float) {
        value = newValue
        target = newValue
        velocity = 0
        animation = nil
    }

    /// Advances by `dt` seconds; returns whether it is still moving.
    @discardableResult
    public mutating func advance(_ dt: Float) -> Bool {
        guard let animation else { return false }
        switch animation {
        case .timed(let duration, let curve):
            elapsed += dt
            let progress = duration > 0 ? elapsed / duration : 1
            if progress >= 1 {
                value = target
                self.animation = nil
                return false
            }
            value = start + (target - start) * curve.value(at: progress)
            return true
        case .spring(let response, let dampingFraction):
            let stiffness = pow(2 * Float.pi / max(response, 0.01), 2)
            let damping = 4 * Float.pi * dampingFraction / max(response, 0.01)
            var remaining = min(dt, 0.1)
            while remaining > 0 {
                let step = min(remaining, 1.0 / 480)
                let force = -stiffness * (value - target) - damping * velocity
                velocity += force * step
                value += velocity * step
                remaining -= step
            }
            if isSettled {
                value = target
                velocity = 0
                self.animation = nil
                return false
            }
            return true
        }
    }

    /// Close enough to rest that the remaining motion is invisible: within a fraction of the distance travelled, and within
    /// what single precision can still resolve at the target's magnitude (a spring at 1,460 points cannot creep closer than
    /// a few thousandths).
    private var isSettled: Bool {
        let range = max(abs(target - start), 1)
        let precision = max(0.0005 * range, abs(target) * 4e-6)
        return abs(value - target) < precision && abs(velocity) < precision * 10
    }

    /// Continues with `velocity` (units per second), as momentum scrolling hands over to a spring.
    public mutating func setVelocity(_ newVelocity: Float) {
        velocity = newVelocity
    }

    public var currentVelocity: Float { velocity }
}
