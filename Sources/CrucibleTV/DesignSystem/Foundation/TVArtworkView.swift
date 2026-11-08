import CrucibleCore
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
    private var artwork: UIImage?

    /// Whether artwork far from the view's shape is shown whole, centred on the placeholder's surface, instead of cropped to
    /// fill: a vertical phone video among landscape ones, a still where a poster was expected.
    var showsOffShapeArtworkWhole = false

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
            if view.isShowingPlaceholder {
                view.showPlaceholder()
            } else if let artwork = view.artwork {
                view.image = view.framed(artwork)
            }
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

    /// Shows artwork from a full URL outside the Plex server, such as a poster the viewer's Seerr serves.
    func setArtwork(url: URL, placeholderSymbol: String) {
        self.placeholderSymbol = placeholderSymbol
        guard url.absoluteString != loadedPath else { return }
        reset()
        loadedPath = url.absoluteString
        loadTask = Task { [weak self] in
            let image = await RemoteImageLoader.shared.image(at: url)
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
        artwork = nil
        image = TVPlaceholder.image(symbol: placeholderSymbol, size: nominalSize, traits: traitCollection, circular: shape == .circle)
    }

    private func display(_ artwork: UIImage) {
        isShowingPlaceholder = false
        loadTask = nil
        self.artwork = artwork
        let shown = framed(artwork)
        guard !UIAccessibility.isReduceMotionEnabled else {
            image = shown
            return
        }
        UIView.transition(with: self, duration: TVMetrics.Duration.fade, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.image = shown
        }
    }

    /// `artwork` as the view draws it: cropped to a circle, drawn whole on the placeholder's surface when its shape is far from
    /// the view's (the focus effect forbids clipping, so the letterbox is part of the image), or unchanged to fill the view.
    private func framed(_ artwork: UIImage) -> UIImage {
        if shape == .circle { return artwork.circularCrop() }
        guard showsOffShapeArtworkWhole, artwork.size.width > 0, nominalSize.width > 0 else { return artwork }
        let aspect = nominalSize.height / nominalSize.width
        guard !ArtworkAspect.fills(artwork.size.height / artwork.size.width, card: aspect) else { return artwork }
        return artwork.centered(onAspect: aspect, background: Theme.Color.surfaceRaised.resolvedColor(with: traitCollection))
    }
}
