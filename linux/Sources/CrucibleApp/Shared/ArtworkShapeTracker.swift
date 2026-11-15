import CrucibleCore
import CrucibleUI
import Foundation

/// Keeps one grid in the shape most of its artwork has (`ArtworkShapeTracker` on the Apple TV): `samples` names each card's
/// image and the shape its kind of item has, `aspect` is the shape `ArtworkAspect` settles on with every measurement known so
/// far, and `onChange` runs when images that load later change it, so the grid can lay itself out again.
@MainActor
final class ArtworkShapeTracker {
    private(set) var aspect = ArtworkAspect.poster
    private let samples: () -> [ArtworkAspect.Sample]
    private let onChange: () -> Void

    init(samples: @escaping () -> [ArtworkAspect.Sample], onChange: @escaping () -> Void) {
        self.samples = samples
        self.onChange = onChange
        ArtworkShapes.shared.observe(self) { [weak self] in self?.shapesDidChange() }
    }

    /// Recomputes the shape from the grid's current cards; true when it changed.
    @discardableResult
    func update() -> Bool {
        let shapes = ArtworkShapes.shared
        let next = ArtworkAspect.dominant(samples(), measured: { shapes.shape(of: $0) })
        guard next != aspect else { return false }
        aspect = next
        return true
    }

    private func shapesDidChange() {
        if update() { onChange() }
    }
}
