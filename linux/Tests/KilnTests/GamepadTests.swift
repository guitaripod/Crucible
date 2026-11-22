import Foundation
import Testing
@testable import Kiln

@MainActor
private final class KeyLog: View {
    var keys: [(key: Key, isRepeat: Bool)] = []
    var tilts: [(Float, Float)] = []
    override var canBecomeFocused: Bool { true }
    override func keyPressed(_ event: KeyEvent) -> Bool {
        keys.append((event.key, event.isRepeat))
        return true
    }
    override func gamepadTilted(x: Float, y: Float) -> Bool {
        tilts.append((x, y))
        return true
    }
}

@Suite("Gamepad")
@MainActor
struct GamepadTests {
    private func focusedLog() throws -> (Window, KeyLog) {
        let window = try Window(offscreen: Size(width: 400, height: 300), gpu: TestGPU.shared)
        let log = KeyLog(frame: Rect(x: 0, y: 0, width: 100, height: 100))
        window.contentView.addSubview(log)
        window.focus.focus(log, animated: false)
        return (window, log)
    }

    @Test func theStickNeedsAFirmPushAndANearReturn() {
        #expect(GamepadDriver.direction(x: 0.6, y: 0.1, current: nil) == .right)
        #expect(GamepadDriver.direction(x: 0.5, y: 0, current: nil) == nil, "a light push is not a direction")
        #expect(GamepadDriver.direction(x: 0.4, y: 0, current: .right) == .right, "easing off holds it")
        #expect(GamepadDriver.direction(x: 0.3, y: 0, current: .right) == nil, "near the middle lets go")
        #expect(GamepadDriver.direction(x: 0.1, y: -0.7, current: .right) == .up)
    }

    @Test func aHeldDirectionRepeatsSoonerAndSooner() throws {
        let (window, log) = try focusedLog()
        let driver = GamepadDriver()
        driver.handle(.button(.dpadDown, down: true), at: 0, in: window)
        #expect(log.keys.map(\.key) == [.down])
        #expect(log.keys.first?.isRepeat == false)
        driver.tick(at: 0.3, in: window)
        #expect(log.keys.count == 1, "no repeat before the delay")
        var time = 0.42
        var gaps: [Double] = []
        var last = time
        for _ in 0..<6 {
            while log.keys.count < 2 + gaps.count {
                driver.tick(at: time, in: window)
                time += 0.001
            }
            gaps.append(time - last)
            last = time
        }
        #expect(log.keys.dropFirst().allSatisfy { $0.isRepeat })
        #expect(zip(gaps.dropFirst(2), gaps.dropFirst(3)).allSatisfy { $1 <= $0 + 0.002 }, "each repeat comes as soon or sooner")
        driver.handle(.button(.dpadDown, down: false), at: time, in: window)
        let count = log.keys.count
        driver.tick(at: time + 5, in: window)
        #expect(log.keys.count == count)
        #expect(!driver.isRepeating)
    }

    @Test func buttonsAreTheRemotesKeys() throws {
        let (window, log) = try focusedLog()
        let driver = GamepadDriver()
        for button in [GamepadButton.south, .east, .back, .start, .north, .leftShoulder, .rightShoulder, .west] {
            driver.handle(.button(button, down: true), at: 0, in: window)
            driver.handle(.button(button, down: false), at: 0, in: window)
        }
        #expect(log.keys.map(\.key) == [.return, .escape, .escape, .mediaPlay, .menu, .tabPrevious, .tabNext, .gamepadWest])
        driver.handle(.rightStick(x: 0.5, y: -0.25), at: 0, in: window)
        #expect(log.tilts.count == 1)
    }

    @Test func aVirtualPadReachesTheWindowThroughSDL() throws {
        let (window, log) = try focusedLog()
        let pads = try #require(Gamepads { window })
        #expect(pads.attachVirtualPad())
        pads.pump()
        #expect(pads.isConnected)
        pads.pressVirtual(.south, down: true)
        pads.pump()
        pads.pressVirtual(.south, down: false)
        pads.pump()
        pads.moveVirtual(axis: 0, to: -1)
        pads.pump()
        #expect(log.keys.map(\.key) == [.return, .left])
    }
}
