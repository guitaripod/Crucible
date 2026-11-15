import Foundation
import Testing
@testable import Kiln

@MainActor
@Suite(.serialized) struct PainterTests {
    let gpu: GPU
    let target: Texture
    let painter: Painter

    init() throws {
        gpu = try GPU(display: nil, surface: nil)
        target = try gpu.texture(width: 640, height: 360, format: .rgba16f, renderable: true)
        painter = Painter(gpu: gpu, target: target)
    }

    private func pixel(_ pixels: [Float], _ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
        let index = (y * target.width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    @Test func aFilledRoundedRectCoversItsInsideAndLeavesItsCornersClear() {
        painter.clear(.black)
        painter.fill(Rect(x: 100, y: 100, width: 200, height: 100), radius: 40, color: .white)
        let pixels = target.download()
        #expect(pixel(pixels, 200, 150).0 > 0.99)
        #expect(pixel(pixels, 101, 101).0 < 0.01)
        #expect(pixel(pixels, 99, 150).0 < 0.01)
        #expect(pixel(pixels, 140, 101).0 > 0.99)
    }

    @Test func translucentFillsBlendOverWhatIsThere() {
        painter.clear(Color(linearRed: 0, green: 0, blue: 1))
        painter.fill(Rect(x: 0, y: 0, width: 640, height: 360), color: Color(linearRed: 1, green: 0, blue: 0, alpha: 0.25))
        let (red, _, blue, _) = pixel(target.download(), 320, 180)
        #expect(abs(red - 0.25) < 0.01)
        #expect(abs(blue - 0.75) < 0.01)
    }

    @Test func hexColoursAreLinearised() {
        let mid = Color(hex: 0x808080)
        #expect(abs(mid.red - 0.2159) < 0.001)
        #expect(Color(hex: 0xFFFFFF).green == 1)
    }

    @Test func aShadowFadesOutwardFromItsShape() {
        painter.clear(.white)
        painter.shadow(Rect(x: 200, y: 100, width: 240, height: 140), radius: 24, blur: 30, offsetY: 0, opacity: 0.8)
        let pixels = target.download()
        let inside = pixel(pixels, 320, 170).0
        let edge = pixel(pixels, 200, 170).0
        let outside = pixel(pixels, 150, 170).0
        #expect(inside < edge)
        #expect(edge < outside)
        #expect(pixel(pixels, 20, 20).0 > 0.999)
    }

    @Test func aVerticalGradientRunsThroughItsStops() {
        painter.clear(.black)
        painter.gradient(Rect(x: 0, y: 0, width: 640, height: 360), vertical: true, stops: [
            (0, Color(linearRed: 0, green: 0, blue: 0)),
            (1, Color(linearRed: 1, green: 1, blue: 1)),
        ])
        let pixels = target.download()
        #expect(pixel(pixels, 10, 0).0 < 0.01)
        #expect(abs(pixel(pixels, 10, 180).0 - 0.5) < 0.01)
        #expect(pixel(pixels, 10, 359).0 > 0.99)
    }

    @Test func artworkIsCroppedToFillAndLinearised() throws {
        let art = try gpu.texture(width: 4, height: 2, format: .rgba8, renderable: false)
        var bytes = [UInt8]()
        for x in 0..<4 {
            let value: UInt8 = x < 2 ? 0 : 0x80
            bytes += [value, value, value, 255]
        }
        bytes += bytes
        _ = bytes.withUnsafeBytes { art.upload($0.baseAddress!, rowBytes: 16) }
        painter.clear(.black)
        painter.image(art, in: Rect(x: 0, y: 0, width: 200, height: 200))
        let pixels = target.download()
        #expect(pixel(pixels, 40, 100).0 < 0.01)
        #expect(abs(pixel(pixels, 160, 100).0 - 0.2159) < 0.01)
    }

    @Test func textIsLaidOutInInterAndDrawnInItsColour() throws {
        let text = TextRenderer(gpu: gpu)
        let style = TextStyle(sizePixels: 48, weight: 700, opticalSize: 32)
        let metrics = text.measure("Continue Watching", style: style)
        #expect(metrics.width > 300 && metrics.width < 520)
        #expect(metrics.lines == 1)
        let label = try #require(try text.texture(for: "Continue Watching", style: style))
        painter.clear(.black)
        painter.text(label.texture, x: 40, y: 40, color: Color(linearRed: 1, green: 0.5, blue: 0))
        let pixels = target.download()
        var lit = 0
        var maxRed: Float = 0
        for y in 40..<(40 + label.metrics.height) {
            for x in 40..<(40 + label.metrics.width) {
                let (red, green, _, _) = pixel(pixels, x, y)
                if red > 0.5 { lit += 1 }
                maxRed = max(maxRed, red)
                if red > 0.01 { #expect(abs(green / red - 0.5) < 0.02) }
            }
        }
        #expect(lit > 2000)
        #expect(maxRed > 0.99)
        #expect(pixel(pixels, 30, 30).0 == 0)
    }

    @Test func longTextWrapsAndEllipsisesAtItsLineLimit() {
        let text = TextRenderer(gpu: gpu)
        var style = TextStyle(sizePixels: 20, weight: 400, opticalSize: 14, maxWidthPixels: 200, maxLines: 2)
        let synopsis = "A retired detective returns to the coastal town where it all began, only to find the past waiting for him at every turn."
        let wrapped = text.measure(synopsis, style: style)
        #expect(wrapped.lines == 2)
        #expect(wrapped.truncated)
        #expect(wrapped.width <= 200)
        style.maxLines = 0
        #expect(text.measure(synopsis, style: style).lines > 2)
    }

    @Test func aCachedLabelIsTheSameTexture() throws {
        let text = TextRenderer(gpu: gpu)
        let style = TextStyle(sizePixels: 24, weight: 500, opticalSize: 18)
        let first = try #require(try text.texture(for: "Movies", style: style))
        let second = try #require(try text.texture(for: "Movies", style: style))
        #expect(first.texture === second.texture)
    }
}
