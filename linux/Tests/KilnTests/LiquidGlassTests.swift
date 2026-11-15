import Testing
@testable import Kiln

@Suite struct LiquidGlassTests {
    @Test func aRegularElementStartsWithTheDocumentedRim() {
        let element = LiquidGlass(primary: .init(centerX: 0, centerY: 0, halfWidth: 100, halfHeight: 20, radius: 20), lightX: 0, lightY: 0)
        #expect(element.variant == .regular)
        #expect(element.rimWidth == 14)
        #expect(element.secondary == nil)
    }
}
