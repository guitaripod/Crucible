import CrucibleUI
import Foundation
import Kiln

/// The buttons of the mini player.
enum MiniZone: Equatable {
    case playPause, expand, close
}

/// The mini player (`RootView.minimizePlayer`): the picture plays on in a corner of the window while the viewer browses,
/// a thin progress line along its foot. Under the pointer it dims a little and offers play or pause in the middle, the
/// full player back at one top corner and Close at the other; a double click also brings the full player back, and a
/// drag moves it to another corner.
extension PlayerScreen {
    private var miniButtonSide: Float { Theme.current.metrics.tv(64) }

    func miniRect(_ zone: MiniZone) -> Rect {
        let metrics = Theme.current.metrics
        let inset = metrics.tv(16)
        let side = miniButtonSide
        switch zone {
        case .playPause:
            let play = metrics.tv(104)
            return Rect(x: bounds.midX - play / 2, y: bounds.midY - play / 2, width: play, height: play)
        case .expand: return Rect(x: inset, y: inset, width: side, height: side)
        case .close: return Rect(x: bounds.width - inset - side, y: inset, width: side, height: side)
        }
    }

    private func miniZone(at point: Point) -> MiniZone? {
        [MiniZone.expand, .close, .playPause].first { miniRect($0).insetBy(-6, -6).contains(point) }
    }

    func miniPointerMoved(to point: Point) {
        if miniHover.target < 1 {
            miniHover.set(1, animation: .timed(duration: 0.12, curve: .easeOut))
            startAnimating()
        }
        let zone = miniZone(at: point)
        guard zone != miniZone else { return }
        miniZone = zone
        setNeedsDisplay()
    }

    func miniPointerExited() {
        miniZone = nil
        miniHover.set(0, animation: .timed(duration: 0.2, curve: .easeOut))
        startAnimating()
    }

    func miniPressed(_ button: MouseButton, at point: Point) -> Bool {
        switch button {
        case .primary:
            if window?.clickCount == 2 && miniZone(at: point) == nil {
                miniPress = nil
                onExpand?()
                return true
            }
            miniPress = (miniZone(at: point), transformToWindow.apply(point), false)
            return true
        case .secondary:
            presentContextMenu(at: transformToWindow.apply(point))
            return true
        default:
            return false
        }
    }

    func miniPointerDragged(to point: Point) {
        guard var press = miniPress else { return }
        let now = transformToWindow.apply(point)
        let delta = Point(x: now.x - press.start.x, y: now.y - press.start.y)
        guard press.dragged || abs(delta.x) + abs(delta.y) > Theme.current.metrics.tv(12) else { return }
        press.dragged = true
        press.start = now
        miniPress = press
        onMiniDrag?(delta)
    }

    func miniReleased(_ button: MouseButton, at point: Point) {
        guard button == .primary, let press = miniPress else { return }
        miniPress = nil
        if press.dragged {
            onMiniDrag?(nil)
            return
        }
        guard let zone = press.zone, miniZone(at: point) == zone else { return }
        switch zone {
        case .playPause: togglePause()
        case .expand: onExpand?()
        case .close: close()
        }
    }

    /// The mini player's progress line, and its buttons under the pointer.
    func drawMiniControls(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        if duration > 0 {
            let height = metrics.tv(6)
            let played = Float(min(max(position / duration, 0), 1))
            context.fill(Rect(x: 0, y: bounds.height - height, width: bounds.width, height: height), color: Color.white.withSRGBAlpha(0.25))
            context.fill(Rect(x: 0, y: bounds.height - height, width: bounds.width * played, height: height), color: theme.palette.accent)
        }
        context.stroke(bounds, width: 1, color: Color.white.withSRGBAlpha(0.18))
        let shown = miniHover.value
        guard shown > 0.01 else { return }
        context.faded(shown) { faded in
            faded.fill(bounds, color: Color.black.withSRGBAlpha(0.35))
            let paused = player?.state.isPaused ?? true
            for zone in [MiniZone.playPause, .expand, .close] {
                let rect = miniRect(zone)
                let lit = miniZone == zone
                faded.fill(rect, radius: rect.width / 2, color: lit ? Color.white.withSRGBAlpha(0.9) : Color.black.withSRGBAlpha(0.55))
                let symbol: Symbol = switch zone {
                case .playPause: paused ? "play.fill" : "pause.fill"
                case .expand: "arrow.up.left.and.arrow.down.right"
                case .close: "xmark"
                }
                let inset = rect.width * (zone == .playPause ? 0.3 : 0.28)
                faded.symbol(symbol, in: rect.insetBy(inset, inset), color: lit ? Color(hex: 0x1A1816) : .white)
            }
        }
    }

    /// The mini player's tooltips.
    func miniTooltip(at point: Point) -> String? {
        switch miniZone(at: point) {
        case .playPause: (player?.state.isPaused ?? true) ? String(localized: "Play") : String(localized: "Pause")
        case .expand: String(localized: "Full Player", comment: "Mini player button: brings the full player back")
        case .close: String(localized: "Close Player", comment: "Player menu")
        case nil: nil
        }
    }
}
