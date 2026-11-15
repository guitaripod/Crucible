import Foundation
import Testing
import CKilnText
@testable import Kiln

@MainActor
@Suite(.serialized) struct PainterTests {
    let gpu: GPU
    let target: Texture
    let painter: Painter

    init() throws {
        gpu = TestGPU.shared
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

    @Test func uprightTextIsSetInStaticCutsThatMatchTheVariableFont() {
        let text = TextStyle(sizePixels: 30, weight: 600, opticalSize: 14)
        let display = TextStyle(sizePixels: 60, weight: 700, opticalSize: 32)
        #expect(TextRenderer.family(for: text).name == "Kiln Inter")
        #expect(TextRenderer.family(for: display).name == "Kiln Inter Display")
        var italic = text
        italic.italic = true
        #expect(TextRenderer.family(for: italic).name == "Inter Variable")
        for (style, opsz) in [(text, 14.0), (display, 32.0)] {
            let sample = "Continue Watching 0123456789"
            let cut = TextRenderer.measure(sample, style: style)
            var raw = kiln_text_style(family: nil, size_px: style.sizePixels, optical_size: opsz, weight: Int32(style.weight), italic: false,
                                      max_width_px: 0, max_lines: 0, alignment: 0, letter_spacing_px: 0, visible_ranges: nil, visible_range_count: 0,
                                      markup: false)
            let variable = "Inter Variable".withCString { family in
                raw.family = family
                return sample.withCString { kiln_text_measure($0, &raw) }
            }
            #expect(cut.width == Int(variable.width), "the static cut sets text exactly as the variable font at its coordinates")
            #expect(cut.height == Int(variable.height))
        }
    }

    @Test func markupSetsRunsBoldAndEscapedTextReadsAsWritten() {
        var style = TextStyle(sizePixels: 30, weight: 400, opticalSize: 14)
        let plain = TextRenderer.measure("Bold & plain", style: style)
        style.markup = true
        let escaped = TextRenderer.measure(TextLayout.escapingMarkup("Bold & plain"), style: style)
        #expect(escaped.width == plain.width, "escaped markup lays out exactly as the plain text")
        let bold = TextRenderer.measure("<b>Bold</b> &amp; plain", style: style)
        #expect(bold.width > plain.width, "the bold run is wider")
        #expect(TextLayout.escapingMarkup("<a href=\"x\">'&'</a>") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
    }

    @Test func colourTextDrawsItsGlyphsInTheColourAndEmojiInTheirOwn() throws {
        let text = TextRenderer(gpu: gpu)
        var style = TextStyle(sizePixels: 64, weight: 400, opticalSize: 14)
        style.inColor = true
        let texture = try #require(try text.colorTexture(for: "I 😀", style: style, color: Color(linearRed: 1, green: 1, blue: 1)))
        #expect(texture.isSRGB)
        painter.clear(.black)
        painter.image(texture, in: Rect(x: 20, y: 20, width: Float(texture.width), height: Float(texture.height)), srgb: true)
        let pixels = target.download()
        var white = 0
        var yellow = 0
        for y in 20..<(20 + texture.height) {
            for x in 20..<(20 + texture.width) {
                let (red, green, blue, _) = pixel(pixels, x, y)
                if red > 0.9, green > 0.9, blue > 0.9 { white += 1 }
                if red > 0.5, green > 0.3, blue < 0.15 { yellow += 1 }
            }
        }
        #expect(white > 20, "the letter is drawn in the colour asked for")
        #expect(yellow > 200, "the emoji keeps its own yellow instead of turning into a white silhouette")
    }

    @Test func aLineLimitCountsLinesAcrossParagraphs() {
        let style = TextStyle(sizePixels: 24, weight: 400, opticalSize: 14, maxWidthPixels: 2000, maxLines: 3)
        let metrics = TextRenderer.measure("One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive.", style: style)
        #expect(metrics.lines == 3, "five short paragraphs stop at three lines in all, not three each")
        #expect(metrics.truncated)
        let short = TextRenderer.measure("One.\nTwo.", style: style)
        #expect(short.lines == 2)
        #expect(!short.truncated)
    }


    @Test func theCaretFollowsTheTextAndAPointFindsItsCharacter() {
        let layout = TextLayout("Night Ferry\nLow Tide", font: Font(size: 20), maxWidth: 400, maxLines: 0, scale: 1)
        let start = layout.caret(atUTF8: 0)
        let afterNight = layout.caret(atUTF8: 5)
        let secondLine = layout.caret(atUTF8: 12)
        #expect(start.minX == 0 && start.minY == 0 && start.height > 10)
        #expect(afterNight.minX > start.minX && afterNight.minY == start.minY)
        #expect(secondLine.minY >= start.maxY - 1 && secondLine.minX == 0, "the second paragraph starts its own line")
        #expect(layout.utf8Index(at: Point(x: afterNight.minX + 1, y: afterNight.midY)) == 5)
        #expect(layout.utf8Index(at: Point(x: 0, y: secondLine.midY)) == 12)
    }


    @Test func textWithEmojiDrawsInColourByItself() {
        #expect(TextLayout("Night Ferry", font: Font(size: 20), scale: 1).isInColor == false)
        #expect(TextLayout("😂 12", font: Font(size: 20), scale: 1).isInColor)
        #expect(TextLayout("\u{2764}\u{FE0F} 3", font: Font(size: 20), scale: 1).isInColor, "a heart asked for as an emoji")
        #expect(TextLayout("★ 8/10 · — “quoted”", font: Font(size: 20), scale: 1).isInColor == false, "typographic marks stay text")
    }


    @Test func aHighlightKeepsTheLayoutAndMapsUTF16ToBytes() {
        let layout = TextLayout("Café Noir", font: Font(size: 20), scale: 1)
        let match = layout.showingOnly(utf16: [(location: 5, length: 4)])
        #expect(match?.size == layout.size, "the highlight mask lines up with the full text")
        #expect(match?.style.visibleByteRanges == [6..<10], "é takes two bytes, so Noir starts at byte 6")
        #expect(layout.showingOnly(utf16: []) == nil)
    }

    @Test func textIsLaidOutInInterAndDrawnInItsColour() throws {
        let text = TextRenderer(gpu: gpu)
        let style = TextStyle(sizePixels: 48, weight: 700, opticalSize: 32)
        let metrics = TextRenderer.measure("Continue Watching", style: style)
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
        var style = TextStyle(sizePixels: 20, weight: 400, opticalSize: 14, maxWidthPixels: 200, maxLines: 2)
        let synopsis = "A retired detective returns to the coastal town where it all began, only to find the past waiting for him at every turn."
        let wrapped = TextRenderer.measure(synopsis, style: style)
        #expect(wrapped.lines == 2)
        #expect(wrapped.truncated)
        #expect(wrapped.width <= 200)
        style.maxLines = 0
        #expect(TextRenderer.measure(synopsis, style: style).lines > 2)
    }

    @Test func aCachedLabelIsTheSameTexture() throws {
        let text = TextRenderer(gpu: gpu)
        let style = TextStyle(sizePixels: 24, weight: 500, opticalSize: 18)
        let first = try #require(try text.texture(for: "Movies", style: style))
        let second = try #require(try text.texture(for: "Movies", style: style))
        #expect(first.texture === second.texture)
    }
}

@MainActor
@Suite struct PainterCostProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KILN_PROBE"] != nil)) func passCost() throws {
        let gpu = TestGPU.shared
        let target = try gpu.texture(width: 3840, height: 2160, format: .rgba16f, renderable: true)
        let painter = Painter(gpu: gpu, target: target)
        let text = TextRenderer(gpu: gpu)
        let style = TextStyle(sizePixels: 29, weight: 600, opticalSize: 17)
        let labels = try (0..<60).map { try #require(try text.texture(for: "Title \($0)", style: style)) }
        for round in 0..<5 {
            let start = ContinuousClock.now
            painter.clear(.black)
            for index in 0..<60 {
                let x = Float(index % 10) * 360 + 40
                let y = Float(index / 10) * 340 + 40
                let rect = Rect(x: x, y: y, width: 260, height: 260)
                painter.shadow(rect, radius: 16, blur: 32, offsetY: 20, opacity: 0.4)
                painter.fill(rect, radius: 16, color: Color(hex: 0x2D2B29))
                painter.fill(Rect(x: x + 14, y: y + 230, width: 232, height: 8), radius: 4, color: Color(hex: 0xFF9F0A))
                painter.text(labels[index].texture, x: x, y: y + 270, color: .white)
                painter.text(labels[index].texture, x: x, y: y + 300, color: Color.white.withAlpha(0.6))
            }
            let cpu = ContinuousClock.now - start
            gpu.finish()
            let total = ContinuousClock.now - start
            print("round \(round): 301 passes cpu \(cpu) total \(total) gpu \(gpu.takeGPUMilliseconds()) ms")
        }
    }
}
