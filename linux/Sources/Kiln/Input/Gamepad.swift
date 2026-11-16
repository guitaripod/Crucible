import CKilnPad
import Foundation

/// A gamepad's buttons in SDL3's standard layout: A south, B east, X west, Y north.
public enum GamepadButton: Int, Sendable {
    case south, east, west, north, back, guide, start, leftStickPress, rightStickPress, leftShoulder, rightShoulder
    case dpadUp, dpadDown, dpadLeft, dpadRight

    var direction: Direction? {
        switch self {
        case .dpadUp: .up
        case .dpadDown: .down
        case .dpadLeft: .left
        case .dpadRight: .right
        default: nil
        }
    }
}

/// What a gamepad did: a button, or where a stick or the triggers now stand (sticks -1 to 1 with y down, triggers 0 to 1).
public enum GamepadEvent: Equatable, Sendable {
    case button(GamepadButton, down: Bool)
    case leftStick(x: Float, y: Float)
    case rightStick(x: Float, y: Float)
    case triggers(left: Float, right: Float)
}

/// What gamepad input means to a window, as the Apple TV reads its remote (docs/LINUX.md §5.4): the d-pad and the left stick
/// move the focus with tvOS-like repeat acceleration, A selects, B and Back go back, Start plays and pauses, Y opens the
/// context menu, the shoulders change tabs, the right stick tilts what has the focus as a pointer would, and the triggers
/// scrub. It only reads events and the time and hands the window keys and gestures, so it is tested without a pad.
@MainActor
public final class GamepadDriver {
    /// Repeat timing: a first repeat after `delay`, then every `interval`, shortened by `acceleration` down to `fastest`.
    public struct Timing: Sendable {
        public var delay: Double = 0.42
        public var interval: Double = 0.16
        public var acceleration: Double = 0.82
        public var fastest: Double = 0.045
        public init() {}
    }

    /// How far a stick goes before it counts as a direction, and how far back before it lets go.
    private static let stickPress: Float = 0.55
    private static let stickRelease: Float = 0.35

    private let timing: Timing
    private var dpad: [Direction] = []
    private var stick: Direction?
    private var held: Direction?
    private var nextRepeat: Double = 0
    private var interval: Double

    public init(timing: Timing = Timing()) {
        self.timing = timing
        interval = timing.interval
    }

    /// Whether a direction is held, so repeats need the clock.
    public var isRepeating: Bool { held != nil }

    public func handle(_ event: GamepadEvent, at time: Double, in window: Window) {
        switch event {
        case .button(let button, let down):
            if let direction = button.direction {
                if down {
                    dpad.removeAll { $0 == direction }
                    dpad.append(direction)
                } else {
                    dpad.removeAll { $0 == direction }
                }
                settle(at: time, in: window)
            } else if down {
                press(button, in: window)
            }
        case .leftStick(let x, let y):
            stick = Self.direction(x: x, y: y, current: stick)
            settle(at: time, in: window)
        case .rightStick(let x, let y):
            window.gamepadTilt(x: x, y: y)
        case .triggers(let left, let right):
            window.gamepadTriggers(left: left, right: right)
        }
    }

    /// Repeats the held direction when its time comes, each repeat a little sooner than the last.
    public func tick(at time: Double, in window: Window) {
        guard let held, time >= nextRepeat else { return }
        window.handleKey(KeyEvent(key: Self.key(held), isRepeat: true))
        nextRepeat = time + interval
        interval = max(timing.fastest, interval * timing.acceleration)
    }

    /// The direction now held: the d-pad's latest, else the stick's. A new direction moves the focus at once.
    private func settle(at time: Double, in window: Window) {
        let now = dpad.last ?? stick
        guard now != held else { return }
        held = now
        interval = timing.interval
        guard let now else { return }
        nextRepeat = time + timing.delay
        window.handleKey(KeyEvent(key: Self.key(now)))
    }

    private func press(_ button: GamepadButton, in window: Window) {
        let key: Key? = switch button {
        case .south: .return
        case .east, .back: .escape
        case .start: .mediaPlay
        case .north: .menu
        case .leftShoulder: .tabPrevious
        case .rightShoulder: .tabNext
        default: nil
        }
        if let key { window.handleKey(KeyEvent(key: key)) }
    }

    /// The stick's direction with hysteresis: it takes a firm push to start one and a near return to the middle to let go.
    static func direction(x: Float, y: Float, current: Direction?) -> Direction? {
        let magnitude = max(abs(x), abs(y))
        if let current, magnitude > stickRelease, Self.dominant(x: x, y: y) == current { return current }
        guard magnitude >= stickPress else { return nil }
        return dominant(x: x, y: y)
    }

    private static func dominant(x: Float, y: Float) -> Direction {
        abs(x) >= abs(y) ? (x < 0 ? .left : .right) : (y < 0 ? .up : .down)
    }

    private static func key(_ direction: Direction) -> Key {
        switch direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

/// The gamepads SDL3 finds (Steam's virtual pads included), read on the main queue: 60 times a second while one is
/// connected and once a second otherwise, to notice one arriving. Their input goes to the window `target` names, the one
/// with the keyboard, and to none while Crucible is in the background.
@MainActor
public final class Gamepads {
    public let driver: GamepadDriver
    /// Called on the first input from a pad after it connects (the couch offer).
    public var onUse: (() -> Void)?
    private let target: @MainActor () -> Window?
    private var timer: DispatchSourceTimer?
    private var isFast = false
    private var used = false

    /// Starts SDL's gamepad subsystem; nil when it cannot.
    public init?(driver: GamepadDriver = GamepadDriver(), target: @escaping @MainActor () -> Window?) {
        guard kiln_pads_open() else { return nil }
        self.driver = driver
        self.target = target
        schedule(fast: false)
    }

    isolated deinit {
        timer?.cancel()
        kiln_pads_close()
    }

    /// Whether a pad is connected.
    public var isConnected: Bool { kiln_pads_count() > 0 }

    /// A virtual pad for headless checks (`CRUCIBLE_VIRTUAL_PAD`), pressed with `pressVirtual` and `moveVirtual`.
    public func attachVirtualPad() -> Bool { kiln_pads_attach_virtual() }

    public func pressVirtual(_ button: GamepadButton, down: Bool) {
        kiln_pads_virtual_button(Int32(button.rawValue), down)
    }

    /// Sets a virtual axis in SDL's order: 0 and 1 the left stick, 2 and 3 the right, 4 and 5 the triggers.
    public func moveVirtual(axis: Int, to value: Float) {
        kiln_pads_virtual_axis(Int32(axis), value)
    }

    private func schedule(fast: Bool) {
        guard timer == nil || fast != isFast else { return }
        isFast = fast
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        let interval: DispatchTimeInterval = fast ? .microseconds(16_667) : .seconds(1)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: fast ? .milliseconds(2) : .milliseconds(200))
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.pump() } }
        source.resume()
        timer = source
    }

    /// Reads what SDL has now; the timer calls it, tests too.
    func pump() {
        var events = [kiln_pad_event](repeating: kiln_pad_event(), count: 64)
        let count = Int(events.withUnsafeMutableBufferPointer { kiln_pads_poll($0.baseAddress, Int32($0.count)) })
        let window = target()
        let now = Window.now()
        for raw in events.prefix(count) {
            switch raw.kind {
            case KILN_PAD_ADDED:
                used = false
            case KILN_PAD_REMOVED:
                break
            default:
                guard let window, let event = Self.event(raw) else { continue }
                if !used {
                    used = true
                    onUse?()
                }
                driver.handle(event, at: now, in: window)
            }
        }
        if let window { driver.tick(at: now, in: window) }
        schedule(fast: isConnected)
    }

    private static func event(_ raw: kiln_pad_event) -> GamepadEvent? {
        switch raw.kind {
        case KILN_PAD_BUTTON: GamepadButton(rawValue: Int(raw.button)).map { .button($0, down: raw.down) }
        case KILN_PAD_LEFT_STICK: .leftStick(x: raw.x, y: raw.y)
        case KILN_PAD_RIGHT_STICK: .rightStick(x: raw.x, y: raw.y)
        case KILN_PAD_TRIGGERS: .triggers(left: max(0, raw.x), right: max(0, raw.y))
        default: nil
        }
    }
}
