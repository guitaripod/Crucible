import Testing
@testable import Kiln

@MainActor
@Suite(.serialized) struct BatchingTests {
    private func solid(_ gpu: GPU, _ value: UInt8) throws -> Texture {
        let texture = try gpu.texture(width: 2, height: 2, format: .rgba8, renderable: false)
        let bytes = [UInt8](repeating: value, count: 16).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }
        _ = bytes.withUnsafeBytes { texture.upload($0.baseAddress!, rowBytes: 8) }
        return texture
    }

    @Test func aBatchKeepsPaintingOrderPastItsSamplerSlots() throws {
        let gpu = TestGPU.shared
        let target = try gpu.texture(width: 64, height: 64, format: .rgba16f, renderable: true)
        let painter = Painter(gpu: gpu, target: target)
        let textures = try (0..<20).map { try solid(gpu, UInt8(10 + $0 * 12)) }
        painter.clear(.black)
        for texture in textures { painter.image(texture, in: Rect(x: 0, y: 0, width: 64, height: 64), srgb: false) }
        painter.fill(Rect(x: 0, y: 0, width: 32, height: 64), color: Color(linearRed: 0, green: 1, blue: 0))
        painter.image(textures[0], in: Rect(x: 0, y: 0, width: 16, height: 16), srgb: false)
        painter.flush()
        let pixels = target.download()
        func red(_ x: Int, _ y: Int) -> Float { pixels[(y * 64 + x) * 4] }
        func green(_ x: Int, _ y: Int) -> Float { pixels[(y * 64 + x) * 4 + 1] }
        #expect(abs(red(48, 32) - Float(10 + 19 * 12) / 255) < 0.01)
        #expect(green(24, 32) > 0.99 && red(24, 32) < 0.01)
        #expect(abs(red(8, 8) - 10.0 / 255) < 0.01)
    }

    @Test func aTextureDrawnExactAndScaledInOneBatchKeepsBoth() throws {
        let gpu = TestGPU.shared
        let target = try gpu.texture(width: 64, height: 32, format: .rgba16f, renderable: true)
        let painter = Painter(gpu: gpu, target: target)
        let mask = try gpu.texture(width: 4, height: 4, format: .r8, renderable: false)
        let coverage = [UInt8](repeating: 255, count: 16)
        _ = coverage.withUnsafeBytes { mask.upload($0.baseAddress!, rowBytes: 4) }
        painter.clear(.black)
        painter.mask(mask, in: Rect(x: 2, y: 2, width: 4, height: 4), color: .white)
        painter.mask(mask, in: Rect(x: 20, y: 4, width: 20, height: 20), color: .white)
        painter.flush()
        let pixels = target.download()
        #expect(pixels[(3 * 64 + 3) * 4] > 0.99)
        #expect(pixels[(14 * 64 + 30) * 4] > 0.99)
        #expect(pixels[(14 * 64 + 50) * 4] < 0.01)
    }

    @Test func aLongGradientRunsThroughItsMiddleStop() throws {
        let gpu = TestGPU.shared
        let target = try gpu.texture(width: 64, height: 100, format: .rgba16f, renderable: true)
        let painter = Painter(gpu: gpu, target: target)
        painter.clear(.black)
        painter.gradient(Rect(x: 0, y: 0, width: 64, height: 100), vertical: true, stops: [
            (0, Color(linearRed: 0, green: 0, blue: 0)),
            (0.5, Color(linearRed: 1, green: 1, blue: 1)),
            (1, Color(linearRed: 0, green: 0, blue: 0)),
        ])
        painter.fill(Rect(x: 0, y: 0, width: 8, height: 8), color: Color(linearRed: 0, green: 0, blue: 1))
        painter.flush()
        let pixels = target.download()
        #expect(pixels[(50 * 64 + 32) * 4] > 0.97)
        #expect(pixels[(99 * 64 + 32) * 4] < 0.03)
        #expect(pixels[(4 * 64 + 4) * 4 + 2] > 0.99)
    }

    @Test func aRowOfGlassBlursTheBackdropOnceAndKeepsEachLabel() throws {
        let window = try Window(offscreen: Size(width: 900, height: 200), gpu: TestGPU.shared)
        window.background = Color(linearRed: 0.2, green: 0.1, blue: 0.05)
        let row = GlassRow()
        row.frame = Rect(x: 0, y: 0, width: 900, height: 200)
        window.contentView.addSubview(row)
        window.render()
        #expect(FrameTrace.glass == 3)
        #expect(FrameTrace.passes < 3 * 9)
        let capture = window.capture()
        for x in [150, 450, 750] {
            let index = (100 * capture.width + x) * 4
            #expect(capture.pixels[index] > 0.99 && capture.pixels[index + 1] > 0.99)
        }
    }

    @Test func glassOverGlassBlursAgainSoTheUpperSeesTheLower() throws {
        let window = try Window(offscreen: Size(width: 400, height: 200), gpu: TestGPU.shared)
        window.background = Color(linearRed: 0.2, green: 0.1, blue: 0.05)
        let stack = GlassStack()
        stack.frame = Rect(x: 0, y: 0, width: 400, height: 200)
        window.contentView.addSubview(stack)
        window.render()
        #expect(FrameTrace.glass == 2)
        #expect(FrameTrace.passes >= 2 * 9)
    }
}

/// Three glass pills far apart in a row, each with a white label square on it, drawn in turn.
@MainActor
private final class GlassRow: View {
    override func draw(_ context: inout DrawContext) {
        for x: Float in [150, 450, 750] {
            context.glass(LiquidGlass(primary: .init(centerX: x, centerY: 100, halfWidth: 90, halfHeight: 30, radius: 30), lightX: x, lightY: 0))
            context.fill(Rect(x: x - 10, y: 90, width: 20, height: 20), color: .white)
        }
    }
}

/// A glass pill with a smaller one over it.
@MainActor
private final class GlassStack: View {
    override func draw(_ context: inout DrawContext) {
        context.glass(LiquidGlass(primary: .init(centerX: 200, centerY: 100, halfWidth: 150, halfHeight: 60, radius: 60), lightX: 200, lightY: 0))
        context.glass(LiquidGlass(primary: .init(centerX: 200, centerY: 100, halfWidth: 60, halfHeight: 25, radius: 25), lightX: 200, lightY: 0))
    }
}
