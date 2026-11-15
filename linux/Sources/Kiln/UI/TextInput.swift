import CKiln
import Foundation

/// A view that takes text from the desktop's input method (text-input-v3): Chinese, Japanese and Korean composition,
/// dead keys and on-screen keyboards. The window turns the input method on while such a view has the focus, tells it
/// where the caret is whenever the view says its state changed, and hands it what the input method sends.
@MainActor
public protocol TextInputClient: AnyObject {
    var textInputState: TextInputState { get }
    /// Applies one batch from the input method, in the protocol's order: the composition shown so far goes, the text
    /// around the caret is deleted, the committed text is inserted, and the new composition shows at the caret.
    func applyTextInput(_ event: TextInputEvent)
}

/// What a text field tells the input method: its text, the caret and the selection's other end as UTF-8 offsets into
/// it, the caret's rectangle in the field's points, and what the field is for.
public struct TextInputState: Equatable, Sendable {
    public enum Purpose: Sendable {
        case normal, password, url, email, number
    }

    public var text: String
    public var cursor: Int
    public var anchor: Int
    public var caret: Rect
    public var purpose: Purpose
    public var multiline: Bool

    public init(text: String, cursor: Int, anchor: Int, caret: Rect, purpose: Purpose = .normal, multiline: Bool = false) {
        self.text = text
        self.cursor = cursor
        self.anchor = anchor
        self.caret = caret
        self.purpose = purpose
        self.multiline = multiline
    }

    /// The protocol's content hint and purpose for the field.
    var contentType: (hint: UInt32, purpose: UInt32) {
        let multiline = multiline ? ZWP_TEXT_INPUT_V3_CONTENT_HINT_MULTILINE.rawValue : 0
        switch purpose {
        case .normal: return (ZWP_TEXT_INPUT_V3_CONTENT_HINT_COMPLETION.rawValue | multiline, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL.rawValue)
        case .password:
            return (ZWP_TEXT_INPUT_V3_CONTENT_HINT_HIDDEN_TEXT.rawValue | ZWP_TEXT_INPUT_V3_CONTENT_HINT_SENSITIVE_DATA.rawValue,
                    ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_PASSWORD.rawValue)
        case .url: return (ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE.rawValue, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_URL.rawValue)
        case .email: return (ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE.rawValue, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_EMAIL.rawValue)
        case .number: return (ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE.rawValue, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_DIGITS.rawValue)
        }
    }
}

/// One batch from the input method. `preedit` is the composition being typed, nil for none, with its cursor as a range of
/// UTF-8 offsets into it (nil to hide the caret); `deleteBefore` and `deleteAfter` count UTF-8 bytes around the caret.
public struct TextInputEvent: Equatable, Sendable {
    public var preedit: String?
    public var preeditCursor: Range<Int>?
    public var commit: String?
    public var deleteBefore: Int
    public var deleteAfter: Int

    public init(preedit: String? = nil, preeditCursor: Range<Int>? = nil, commit: String? = nil, deleteBefore: Int = 0, deleteAfter: Int = 0) {
        self.preedit = preedit
        self.preeditCursor = preeditCursor
        self.commit = commit
        self.deleteBefore = deleteBefore
        self.deleteAfter = deleteAfter
    }

    /// Applies the batch to `text` with the caret at character `caret`: the deletion around the caret, then the commit
    /// at it. Returns the new text and caret; the composition is the field's to show.
    public func applied(to text: String, caret: Int) -> (text: String, caret: Int) {
        var characters = Array(text)
        var caret = min(max(caret, 0), characters.count)
        if deleteBefore > 0 || deleteAfter > 0 {
            let utf8Caret = String(characters[..<caret]).utf8.count
            let start = TextInputEvent.characterIndex(in: characters, atUTF8: max(utf8Caret - deleteBefore, 0), roundingUp: false)
            let end = TextInputEvent.characterIndex(in: characters, atUTF8: utf8Caret + deleteAfter, roundingUp: true)
            characters.removeSubrange(start..<max(start, end))
            caret = start
        }
        if let commit, !commit.isEmpty {
            characters.insert(contentsOf: Array(commit), at: caret)
            caret += commit.count
        }
        return (String(characters), caret)
    }

    /// The character boundary at a UTF-8 offset into `characters`, or the nearest one on the side asked for.
    public static func characterIndex(in characters: [Character], atUTF8 offset: Int, roundingUp: Bool) -> Int {
        var bytes = 0
        for (index, character) in characters.enumerated() {
            if bytes >= offset { return index }
            let next = bytes + character.utf8.count
            if next > offset { return roundingUp ? index + 1 : index }
            bytes = next
        }
        return characters.count
    }

    init(_ raw: kiln_wl_text_input_event) {
        preedit = raw.preedit.map { String(cString: $0) }
        preeditCursor = raw.preedit_cursor_begin < 0 ? nil
            : Int(raw.preedit_cursor_begin)..<Int(max(raw.preedit_cursor_begin, raw.preedit_cursor_end))
        commit = raw.commit.map { String(cString: $0) }
        deleteBefore = Int(raw.delete_before)
        deleteAfter = Int(raw.delete_after)
    }
}
