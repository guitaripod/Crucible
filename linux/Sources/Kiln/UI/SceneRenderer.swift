import Foundation

/// Draws a view tree into a half-float target in linear light: each view's content, then its subviews, then its overlay,
/// with clips, alpha and transforms composed down the tree. Glass blurs what has been drawn so far and composites over it.
@MainActor
final class SceneRenderer {
    let gpu: GPU
    let text: TextRenderer
    let symbols: SymbolRenderer
    private(set) var target: Texture
    private(set) var painter: Painter
    private var glassRenderer: LiquidGlassRenderer?
    private var backdropCopy: Texture?
    var scale: Float = 1
    private var readback: Readback?
    private var readbackStarted = false
    private var luminanceMap: (width: Int, height: Int, values: [Float])?

    init(gpu: GPU, width: Int, height: Int) throws(RenderError) {
        self.gpu = gpu
        text = TextRenderer(gpu: gpu)
        symbols = SymbolRenderer(gpu: gpu)
        target = try gpu.texture(width: max(width, 1), height: max(height, 1), format: .rgba16f, renderable: true)
        painter = Painter(gpu: gpu, target: target)
    }

    func resize(width: Int, height: Int) throws(RenderError) {
        guard width != target.width || height != target.height else { return }
        target = try gpu.texture(width: max(width, 1), height: max(height, 1), format: .rgba16f, renderable: true)
        painter = Painter(gpu: gpu, target: target)
        glassRenderer = nil
        backdropCopy = nil
    }

    func render(root: View, background: Color) {
        collectReadback()
        readbackStarted = false
        painter.clip = nil
        painter.clear(background)
        let context = DrawContext(renderer: self, transform: Affine(scale: scale), alpha: 1, clip: nil)
        draw(root, in: context)
        painter.clip = nil
        text.endFrame()
    }

    private func draw(_ view: View, in parent: DrawContext) {
        guard !view.isHidden, view.alpha > 0.001 else { return }
        var context = parent
        context.transform = parent.transform.concatenating(view.transformToSuperview)
        context.alpha = parent.alpha * view.alpha
        let pixels = context.transform.apply(view.bounds)
        let reach = view.overdraw * context.transform.scale
        if let clip = context.clip, !clip.intersects(pixels.insetBy(-reach, -reach)) { return }
        view.draw(&context)
        var inner = context
        if view.clipsToBounds {
            inner.clip = context.clip.map { $0.intersection(pixels) } ?? pixels
        }
        inner.transform = context.transform.concatenating(Affine(scale: 1, tx: -view.contentOffset.x, ty: -view.contentOffset.y))
        if inner.clip?.isEmpty != true {
            for subview in view.subviews { draw(subview, in: inner) }
        }
        view.drawOverlay(&context)
    }

    /// Blurs the frame so far into the frost pyramid and composites `element` (in target pixels) over it.
    func drawGlass(_ element: LiquidGlass, clip: Rect?, opacity: Float) {
        guard opacity > 0.001 else { return }
        do {
            if glassRenderer == nil { glassRenderer = try LiquidGlassRenderer(gpu: gpu, width: target.width, height: target.height) }
            if backdropCopy == nil { backdropCopy = try gpu.texture(width: target.width, height: target.height, format: .rgba16f, renderable: true) }
        } catch {
            return
        }
        guard let glassRenderer, let backdropCopy else { return }
        let copier = Painter(gpu: gpu, target: backdropCopy)
        copier.copy(target)
        glassRenderer.blur(backdropCopy)
        if readback == nil && !readbackStarted {
            readback = glassRenderer.tiny.beginReadback()
            readbackStarted = true
        }
        var area = element.bounds
        if let clip { area = area.intersection(clip) }
        guard !area.isEmpty else { return }
        glassRenderer.composite(scene: backdropCopy, into: target, element: element, rect: area, opacity: opacity)
    }

    private func collectReadback() {
        guard let readback, let pixels = readback.poll() else { return }
        var values = [Float](repeating: 0, count: readback.width * readback.height)
        for index in values.indices {
            values[index] = 0.2126 * pixels[index * 4] + 0.7152 * pixels[index * 4 + 1] + 0.0722 * pixels[index * 4 + 2]
        }
        luminanceMap = (readback.width, readback.height, values)
        self.readback = nil
    }

    /// The mean linear luminance of what was drawn under `rect` (target pixels) before the first glass of a recent frame,
    /// from the blur pyramid's smallest level read back a frame or two late; nil before the first reading.
    func backdropLuminance(in rect: Rect) -> Float? {
        guard let map = luminanceMap, map.width > 0, map.height > 0 else { return nil }
        let sx = Float(map.width) / Float(target.width)
        let sy = Float(map.height) / Float(target.height)
        let x0 = max(0, Int((rect.minX * sx).rounded(.down)))
        let y0 = max(0, Int((rect.minY * sy).rounded(.down)))
        let x1 = min(map.width, max(x0 + 1, Int((rect.maxX * sx).rounded(.up))))
        let y1 = min(map.height, max(y0 + 1, Int((rect.maxY * sy).rounded(.up))))
        guard x1 > x0, y1 > y0 else { return nil }
        var sum: Float = 0
        for y in y0..<y1 {
            for x in x0..<x1 { sum += map.values[y * map.width + x] }
        }
        return sum / Float((x1 - x0) * (y1 - y0))
    }
}
