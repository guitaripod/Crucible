import CKiln

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = Modifiers(rawValue: UInt32(KILN_MOD_SHIFT))
    public static let control = Modifiers(rawValue: UInt32(KILN_MOD_CTRL))
    public static let alt = Modifiers(rawValue: UInt32(KILN_MOD_ALT))
    public static let `super` = Modifiers(rawValue: UInt32(KILN_MOD_SUPER))
}

/// A key as the keymap reads it: the keysym (`Key`), the text it types and the modifiers held.
public struct KeyEvent: Sendable {
    public let key: Key
    public let text: String
    public let modifiers: Modifiers
    public let isRepeat: Bool

    public init(key: Key, text: String = "", modifiers: Modifiers = [], isRepeat: Bool = false) {
        self.key = key
        self.text = text
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    /// Printable text with no command modifier held: what typing into a field or "type to search" takes.
    public var typedText: String? {
        guard !text.isEmpty, modifiers.isDisjoint(with: [.control, .alt, .super]) else { return nil }
        guard let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return text
    }
}

/// An X keysym, with names for the keys Kiln and Crucible bind.
public struct Key: Hashable, Sendable {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }

    public static let left = Key(0xFF51)
    public static let up = Key(0xFF52)
    public static let right = Key(0xFF53)
    public static let down = Key(0xFF54)
    public static let pageUp = Key(0xFF55)
    public static let pageDown = Key(0xFF56)
    public static let home = Key(0xFF50)
    public static let end = Key(0xFF57)
    public static let `return` = Key(0xFF0D)
    public static let keypadEnter = Key(0xFF8D)
    public static let escape = Key(0xFF1B)
    public static let tab = Key(0xFF09)
    public static let leftTab = Key(0xFE20)
    public static let backspace = Key(0xFF08)
    public static let delete = Key(0xFFFF)
    public static let space = Key(0x0020)
    public static let menu = Key(0xFF67)
    public static let f1 = Key(0xFFBE)
    public static let f10 = Key(0xFFC7)
    public static let f11 = Key(0xFFC8)
    public static let back = Key(0x1008FF26)
    public static let forward = Key(0x1008FF27)

    /// A letter or digit key by its lowercase character (`Key.character("f")`).
    public static func character(_ character: Character) -> Key {
        Key(character.unicodeScalars.first.map { $0.value } ?? 0)
    }

    public var isArrow: Bool { self == .left || self == .right || self == .up || self == .down }

    public var direction: Direction? {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        default: nil
        }
    }

    public var isActivation: Bool { self == .return || self == .keypadEnter || self == .space }
}

/// One frame of scrolling from a wheel or a touchpad, in points; positive moves the content's view right and down
/// (the way the wheel turns it, before natural scrolling is applied by the compositor).
public struct ScrollEvent: Sendable {
    public enum Source: Sendable { case wheel, finger, continuous, wheelTilt }

    public var dx: Float
    public var dy: Float
    /// Wheel notches (fractions for high-resolution wheels); zero from a touchpad.
    public var notchesX: Float
    public var notchesY: Float
    public var source: Source
    /// The fingers left the touchpad: momentum starts here.
    public var ended: Bool
    public var modifiers: Modifiers
    public var timeMilliseconds: UInt32

    public init(dx: Float, dy: Float, notchesX: Float = 0, notchesY: Float = 0, source: Source, ended: Bool = false,
                modifiers: Modifiers = [], timeMilliseconds: UInt32 = 0) {
        self.dx = dx
        self.dy = dy
        self.notchesX = notchesX
        self.notchesY = notchesY
        self.source = source
        self.ended = ended
        self.modifiers = modifiers
        self.timeMilliseconds = timeMilliseconds
    }

    public var isDiscrete: Bool { source == .wheel || source == .wheelTilt }
}

public enum MouseButton: Hashable, Sendable {
    case primary, middle, secondary, back, forward, other(UInt32)

    /// From a Linux input event code (`BTN_LEFT` and friends).
    public init(code: UInt32) {
        switch code {
        case 0x110: self = .primary
        case 0x111: self = .secondary
        case 0x112: self = .middle
        case 0x113, 0x116: self = .back
        case 0x114, 0x115: self = .forward
        default: self = .other(code)
        }
    }
}

public enum Cursor: Sendable {
    case `default`, pointer, text, hidden

    var raw: kiln_cursor {
        switch self {
        case .default: KILN_CURSOR_DEFAULT
        case .pointer: KILN_CURSOR_POINTER
        case .text: KILN_CURSOR_TEXT
        case .hidden: KILN_CURSOR_HIDDEN
        }
    }
}
