import Foundation
import Testing
@testable import Kiln

@MainActor
private final class Spoken: View {
    let name: String
    let role: AccessibilityRole
    let exposes: Bool
    let focusable: Bool

    init(_ name: String, role: AccessibilityRole, exposes: Bool = true, focusable: Bool = false, frame: Rect = Rect(x: 0, y: 0, width: 100, height: 40)) {
        self.name = name
        self.role = role
        self.exposes = exposes
        self.focusable = focusable
        super.init(frame: frame)
    }

    override var canBecomeFocused: Bool { focusable }
    override var accessibilityLabel: String? { name }
    override var accessibilityRole: AccessibilityRole { role }
    override var accessibilityExposesChildren: Bool { exposes }
}

@Suite("Accessibility tree")
@MainActor
struct AccessibilityTreeTests {
    @Test func viewsWithoutARoleLendTheirPlaceToTheirChildren() throws {
        let window = try Window(offscreen: Size(width: 400, height: 300), gpu: TestGPU.shared)
        let container = View(frame: Rect(x: 0, y: 0, width: 400, height: 300))
        let play = Spoken("Play", role: .button, focusable: true)
        let heading = Spoken("Extras", role: .heading)
        let hidden = Spoken("Hidden", role: .label)
        hidden.isHidden = true
        let panel = Spoken("Server, Connected", role: .label, exposes: false)
        panel.addSubview(Spoken("Connected", role: .label))
        [play, heading, hidden, panel].forEach(container.addSubview)
        window.contentView.addSubview(container)
        window.focus.focus(play, animated: false)

        let snapshot = AccessibilityTree.snapshot(of: window, title: "Crucible")
        let root = try #require(snapshot.nodes.first)
        #expect(root.id == AccessibilityTree.rootID)
        #expect(root.role == .window)
        #expect(root.label == "Crucible")
        let labels = root.children.compactMap { id in snapshot.nodes.first { $0.id == id }?.label }
        #expect(labels == ["Play", "Extras", "Server, Connected"], "the container is skipped and the hidden view left out")
        #expect(snapshot.nodes.count == 4, "the panel speaks for the label inside it")
        #expect(snapshot.focus == play.accessibilityID)
        #expect(snapshot.nodes.first { $0.id == play.accessibilityID }?.isFocusable == true)
    }

    @Test func focusOutsideTheTreeIsTheWindow() throws {
        let window = try Window(offscreen: Size(width: 200, height: 100), gpu: TestGPU.shared)
        #expect(AccessibilityTree.snapshot(of: window, title: "Crucible").focus == AccessibilityTree.rootID)
    }

    @Test func defaultRolesFollowFocusAndText() {
        let label = Label("Night Ferry", font: Font(size: 20), color: .white)
        #expect(label.accessibilityRole == .label)
        label.isHeading = true
        #expect(label.accessibilityRole == .heading)
        label.text = ""
        #expect(label.accessibilityRole == .none, "an empty label is not read")
        #expect(Tile("card", frame: .zero).accessibilityRole == .button)
        #expect(View().accessibilityRole == .none)
    }
}
