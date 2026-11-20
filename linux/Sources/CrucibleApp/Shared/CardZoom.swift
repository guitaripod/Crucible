import CrucibleUI
import Foundation
import Kiln

/// Ctrl with plus and minus make the cards of every shelf and grid bigger or smaller, Ctrl+0 puts them back, and the size
/// is kept between launches (the iPad's command model on a desk).
@MainActor
enum CardZoom {
    enum Step {
        case larger, smaller, reset
    }

    private static let key = "cardZoom"
    private static let increment: Float = 0.1
    private static let range: ClosedRange<Float> = 0.7...1.6
    /// Every size a step lands on, for Settings' choice of one.
    static let sizes: [Float] = stride(from: range.lowerBound, through: range.upperBound + 0.01, by: increment).map { ($0 * 10).rounded() / 10 }

    static var saved: Float {
        let stored = Float(UserDefaults.standard.double(forKey: key))
        return stored > 0 ? min(max(stored, range.lowerBound), range.upperBound) : 1
    }

    /// The step a key asks for with Ctrl held: plus (or the equals key it shares), minus, or zero.
    static func step(for key: Key) -> Step? {
        switch key {
        case .character("="), .character("+"), Key(0xFFAB): .larger
        case .character("-"), Key(0xFFAD): .smaller
        case .character("0"), Key(0xFFB0): .reset
        default: nil
        }
    }

    /// How far a touchpad scrolls with Ctrl held for one step, in points.
    private static let scrollPerStep: Float = 60
    private static var scrolled: Float = 0

    /// The step a scroll with Ctrl held asks for: a wheel notch up is larger and down smaller; a touchpad moves one step
    /// for every `scrollPerStep` points it travels.
    static func step(for event: ScrollEvent) -> Step? {
        if event.isDiscrete {
            scrolled = 0
            guard event.notchesY != 0 else { return nil }
            return event.notchesY < 0 ? .larger : .smaller
        }
        scrolled += event.dy
        guard abs(scrolled) >= scrollPerStep else { return nil }
        defer { scrolled = 0 }
        return scrolled < 0 ? .larger : .smaller
    }

    static func apply(_ step: Step) {
        let current = Theme.current.cardZoom
        switch step {
        case .larger: set(current + increment)
        case .smaller: set(current - increment)
        case .reset: set(1)
        }
    }

    /// Sets the card size to `zoom`, kept within 70% to 160% in steps of ten, and keeps it for the next launch.
    static func set(_ zoom: Float) {
        let theme = Theme.current
        theme.cardZoom = (min(max(zoom, range.lowerBound), range.upperBound) * 10).rounded() / 10
        UserDefaults.standard.set(Double(theme.cardZoom), forKey: key)
    }
}

extension Window {
    /// Lays every view out again after a density, appearance or card size change.
    func relayoutEverything() {
        func walk(_ view: View) {
            view.setNeedsLayout()
            view.setNeedsDisplay()
            view.subviews.forEach(walk)
        }
        walk(contentView)
    }
}
