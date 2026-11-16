import Foundation

/// Draws a view tree into a half-float target in linear light: each view's content, then its subviews, then its overlay,
/// with clips, alpha and transforms composed down the tree. Glass blurs what has been drawn so far and composites over it.
@MainActor
final class SceneRenderer {
    let gpu: GPU
    let text: TextRenderer
    let symbols: SymbolRenderer
    let shapes: ShapeRenderer
    private(set) var target: Texture
    private(set) var painter: Painter
    private var glassRenderer: LiquidGlassRenderer?
    private var backdropCopy: Texture?
    private var backdropCopier: Painter?
    var scale: Float = 1
    private var readback: Readback?
    private var readbackStarted = false
    private var luminanceMap: (width: Int, height: Int, values: [Float])?
    /// Whether glass blurred the backdrop earlier in this frame, so the next glass may reuse it.
    private var blurredThisFrame = false
    /// How many labels this frame may still rasterise at a lifted scale; the rest draw stretched until a later frame.
    private var sharpTextBudget = 0
    private static let sharpTextPerFrame = 12
    /// How far around glass, in target pixels, the frost and the refraction reach for what is behind it.
    private static let glassReach: Float = 128

    init(gpu: GPU, width: Int, height: Int) throws(RenderError) {
        self.gpu = gpu
        text = TextRenderer(gpu: gpu)
        symbols = SymbolRenderer(gpu: gpu)
        shapes = ShapeRenderer(gpu: gpu)
        viewport = (max(width, 1), max(height, 1))
        target = try gpu.texture(width: Self.allocated(viewport.width), height: Self.allocated(viewport.height), format: .rgba16f, renderable: true)
        painter = Painter(gpu: gpu, target: target)
    }

    /// The part of `target` the window shows, from its top-left corner. The target and the glass's own textures are
    /// allocated a step larger (`allocated`), so a window resized by dragging its edge draws into what is there instead of
    /// allocating a new set of full-size textures for every size it passes through.
    private(set) var viewport: (width: Int, height: Int)

    /// A size rounded up to the next 256 pixels.
    static func allocated(_ pixels: Int) -> Int {
        (pixels + 255) / 256 * 256
    }

    /// Shows `width` by `height` pixels, reallocating only when the window outgrows the target or shrinks well inside it.
    func resize(width: Int, height: Int) throws(RenderError) {
        viewport = (max(width, 1), max(height, 1))
        let fits = viewport.width <= target.width && viewport.height <= target.height
        let roomy = viewport.width * 4 >= target.width * 3 || viewport.height * 4 >= target.height * 3
        guard !fits || !roomy else { return }
        target = try gpu.texture(width: Self.allocated(viewport.width + 128), height: Self.allocated(viewport.height + 128), format: .rgba16f, renderable: true)
        painter = Painter(gpu: gpu, target: target)
        glassRenderer = nil
        backdropCopy = nil
        backdropCopier = nil
    }

    func render(root: View, background: Color) {
        collectReadback()
        readbackStarted = false
        blurredThisFrame = false
        sharpTextBudget = Self.sharpTextPerFrame
        painter.clip = nil
        painter.clear(background)
        let context = DrawContext(renderer: self, transform: Affine(scale: scale), alpha: 1, clip: nil)
        draw(root, in: context)
        painter.flush()
        painter.clip = nil
        text.endFrame()
        shapes.endFrame()
        symbols.endFrame()
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

    /// `layout`'s text rasterised at `pixelScale` pixels per point when that differs from the window's (a lifted card or
    /// row), so it is drawn at its own size and stays sharp instead of a stretched mask; nil when the scales match, or when
    /// this frame has rasterised its share and the text is not ready yet (it then draws stretched for a frame or two). The
    /// scale is taken in steps of 1/64, under half a pixel on any title, so a lift reuses a handful of rasterisations
    /// instead of shaping and uploading the text anew on almost every frame of the spring.
    func sharpText(_ layout: TextLayout, pixelScale: Float) -> Texture? {
        guard !layout.text.isEmpty, abs(pixelScale / scale - 1) > 0.002, pixelScale / scale < 2 else { return nil }
        let style = layout.style(atScale: (pixelScale * 64).rounded() / 64)
        if !text.hasTexture(for: layout.text, style: style) {
            guard sharpTextBudget > 0 else { return nil }
            sharpTextBudget -= 1
        }
        return (try? text.texture(for: layout.text, style: style))?.texture
    }

    /// Builds every pipeline Kiln draws with on a small target (the batch, the long gradient and the glow, clears and
    /// copies, the blur and the glass), so the first screen that needs one does not stop to compile it; with a warm shader
    /// cache this only loads them.
    func prewarm() {
        guard let scratch = try? gpu.texture(width: 64, height: 64, format: .rgba16f, renderable: true),
              let copy = try? gpu.texture(width: 64, height: 64, format: .rgba16f, renderable: true),
              let mask = try? gpu.texture(width: 4, height: 4, format: .r8, renderable: false),
              let art = try? gpu.texture(width: 4, height: 4, format: .rgba8, renderable: false),
              let glass = try? LiquidGlassRenderer(gpu: gpu, width: 64, height: 64) else { return }
        let zeros = [UInt8](repeating: 0, count: 64)
        zeros.withUnsafeBytes { bytes in
            _ = mask.upload(bytes.baseAddress!, rowBytes: 4)
            _ = art.upload(bytes.baseAddress!, rowBytes: 16)
        }
        let painter = Painter(gpu: gpu, target: scratch)
        let box = Rect(x: 8, y: 8, width: 48, height: 48)
        painter.clear(.black)
        painter.fill(box, radius: 6, color: .white)
        painter.image(art, in: box, radius: 6)
        painter.mask(mask, in: Rect(x: 8, y: 8, width: 4, height: 4), color: .white)
        painter.gradient(box, vertical: true, stops: [(0, .black), (0.5, .white), (1, .black)])
        painter.glow(in: box, radius: 6, center: Point(x: 32, y: 32), glowRadius: 16, color: .white)
        painter.flush()
        Painter(gpu: gpu, target: copy).copy(scratch)
        glass.blur(copy)
        let shape = LiquidGlass.Shape(centerX: 32, centerY: 32, halfWidth: 20, halfHeight: 12, radius: 12)
        glass.composite(scene: copy, into: scratch, element: LiquidGlass(primary: shape, lightX: 32, lightY: 0), opacity: 1, overlay: true)
    }

    /// Composites `element` (in target pixels) over the frame, through the frost pyramid blurred from what has been drawn.
    /// Glass reuses the pyramid an earlier glass of this frame blurred when nothing it would see has been drawn since (the
    /// labels on that glass aside) and it does not overlap that glass, so a row of glass buttons blurs the backdrop once.
    func drawGlass(_ element: LiquidGlass, clip: Rect?, opacity: Float) {
        guard opacity > 0.001 else { return }
        FrameTrace.glass += 1
        do {
            if glassRenderer == nil { glassRenderer = try LiquidGlassRenderer(gpu: gpu, width: target.width, height: target.height) }
            if backdropCopy == nil { backdropCopy = try gpu.texture(width: target.width, height: target.height, format: .rgba16f, renderable: true) }
        } catch {
            return
        }
        guard let glassRenderer, let backdropCopy else { return }
        let copier = backdropCopier ?? Painter(gpu: gpu, target: backdropCopy)
        backdropCopier = copier
        var area = element.bounds
        if let clip { area = area.intersection(clip) }
        guard !area.isEmpty else { return }
        let shape = element.shapeBounds
        let reach = Self.glassReach + element.refraction
        let seen = shape.insetBy(-reach, -reach)
        let current = blurredThisFrame && !painter.drawnSinceBlur(intersects: seen) && !painter.glassSinceBlur.contains { $0.intersects(shape) }
        painter.flush()
        if !current {
            copier.copy(target)
            glassRenderer.blur(backdropCopy)
            painter.backdropBlurred()
            blurredThisFrame = true
            if readback == nil && !readbackStarted {
                readback = glassRenderer.tiny.beginReadback()
                readbackStarted = true
            }
        }
        glassRenderer.composite(scene: backdropCopy, into: target, element: element, rect: area, opacity: opacity, overlay: true)
        painter.glassDrawn(shape)
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

    /// The performance HUD: the frame trace's line on a dark plate at the top left.
    func drawHUD(_ line: String) {
        painter.clip = nil
        var style = TextStyle(sizePixels: Double(13 * scale), weight: 500, opticalSize: 14, maxWidthPixels: viewport.width - Int(24 * scale), maxLines: 3)
        style.alignment = .leading
        guard let label = try? text.texture(for: line, style: style) else { return }
        let rect = Rect(x: 8 * scale, y: 8 * scale, width: Float(label.metrics.width) + 16 * scale, height: Float(label.metrics.height) + 12 * scale)
        painter.fill(rect, radius: 6 * scale, color: Color.black.withAlpha(0.72))
        painter.text(label.texture, x: rect.x + 8 * scale, y: rect.y + 6 * scale, color: Color(hex: 0x7CFC9A))
        painter.flush()
    }
}
