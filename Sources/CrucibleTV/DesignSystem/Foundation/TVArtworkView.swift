import CrucibleDesign
import UIKit

/// An image view with the system tvOS focus treatment (lift, parallax and specular sheen while an
/// ancestor is focused) that loads its picture through `TVImagePipeline`: a placeholder first, a
/// fade-in when the artwork arrives, and cancellation when it is reused or removed.
///
/// The view must not clip to its bounds: `clipsToBounds` switches the system focus effect off. Rounded
/// corners come from `layer.cornerRadius` instead.
final class TVArtworkView: UIImageView {
    private let kind: TVImagePipeline.Kind
    private let nominalSize: CGSize
    private let shape: TVCardStyle.Shape
    private var placeholderSymbol: String
    private var loadTask: Task<Void, Never>?
    private var loadedPath: String?
    private var isShowingPlaceholder = true

    init(kind: TVImagePipeline.Kind, nominalSize: CGSize, shape: TVCardStyle.Shape = .rounded, placeholderSymbol: String) {
        self.kind = kind
        self.nominalSize = nominalSize
        self.shape = shape
        self.placeholderSymbol = placeholderSymbol
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        adjustsImageWhenAncestorFocused = true
        switch shape {
        case .rounded:
            layer.cornerCurve = .continuous
            layer.cornerRadius = TVMetrics.Card.cornerRadius
        case .circle:
            masksFocusEffectToContents = true
        }
        showPlaceholder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TVArtworkView, _: UITraitCollection) in
            if view.isShowingPlaceholder { view.showPlaceholder() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    /// Shows `path`'s artwork, or the placeholder when it is nil. Setting the path already on screen is a no-op.
    func setArtwork(path: String?, placeholderSymbol: String) {
        if placeholderSymbol != self.placeholderSymbol {
            self.placeholderSymbol = placeholderSymbol
            if isShowingPlaceholder { showPlaceholder() }
        }
        guard path != loadedPath || (path != nil && isShowingPlaceholder && loadTask == nil) else { return }
        reset()
        loadedPath = path
        guard let path else { return }
        let scale = max(traitCollection.displayScale, 1)
        let width = nominalSize.width
        let kind = kind
        loadTask = Task { [weak self] in
            let image = await TVImagePipeline.load(path: path, pointWidth: width, scale: scale, kind: kind)
            guard !Task.isCancelled, let self else { return }
            guard let image else {
                self.loadTask = nil
                return
            }
            self.display(image)
        }
    }

    /// Cancels any load in flight and returns to the placeholder.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        loadedPath = nil
        showPlaceholder()
    }

    private func showPlaceholder() {
        isShowingPlaceholder = true
        image = TVPlaceholder.image(symbol: placeholderSymbol, size: nominalSize, traits: traitCollection, circular: shape == .circle)
    }

    private func display(_ artwork: UIImage) {
        isShowingPlaceholder = false
        loadTask = nil
        let shown = shape == .circle ? artwork.circularCrop() : artwork
        guard !UIAccessibility.isReduceMotionEnabled else {
            image = shown
            return
        }
        UIView.transition(with: self, duration: TVMetrics.Duration.fade, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.image = shown
        }
    }
}
