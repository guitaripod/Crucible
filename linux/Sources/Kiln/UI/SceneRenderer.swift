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
        var area = element.bounds
        if let clip { area = area.intersection(clip) }
        guard !area.isEmpty else { return }
        glassRenderer.composite(scene: backdropCopy, into: target, element: element, rect: area, opacity: opacity)
    }
}
