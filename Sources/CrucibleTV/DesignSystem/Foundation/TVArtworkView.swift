import CrucibleCore
import CrucibleDesign
import UIKit

/// An image view with the system tvOS focus treatment (lift, parallax and specular sheen while an
/// ancestor is focused) that loads its picture through `TVImagePipeline`: a placeholder first, a
/// fade-in when the artwork arrives, and cancellation when it is reused or removed.
///
/// The view must not clip to its bounds: `clipsToBounds` switches the system focus effect off. So every picture it shows
/// is drawn in the view's exact shape first, cropped to its aspect with the corners cut out, and the focus effect is masked
/// to that shape where the system does not take it from `layer.cornerRadius` (`Glass.systemShapesFocusEffect`). A picture of
/// another shape would spill past the card at rest and be cut back once it took focus.
final class TVArtworkView: UIImageView {
    private let kind: TVImagePipeline.Kind
    private let nominalSize: CGSize
    private let shape: TVCardStyle.Shape
    private var placeholderSymbol: String
    private let cornerRadius: CGFloat
    private var loadTask: Task<Void, Never>?
    private var redrawTask: Task<Void, Never>?
    private var loadedPath: String?
    private var isShowingPlaceholder = true
    private var artwork: UIImage?

    /// Whether artwork far from the view's shape is shown whole, centred on the placeholder's surface, instead of cropped to
    /// fill: a vertical phone video among landscape ones, a still where a poster was expected.
    var showsOffShapeArtworkWhole = false

    /// `cornerRadius` is the radius of a rounded view, baked into every picture it shows.
    init(
        kind: TVImagePipeline.Kind,
        nominalSize: CGSize,
        shape: TVCardStyle.Shape = .rounded,
        cornerRadius: CGFloat = TVMetrics.Card.cornerRadius,
        placeholderSymbol: String
    ) {
        self.kind = kind
        self.nominalSize = nominalSize
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = placeholderSymbol
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        adjustsImageWhenAncestorFocused = true
        masksFocusEffectToContents = shape == .circle || !Glass.systemShapesFocusEffect
        if shape == .rounded {
            layer.cornerCurve = .continuous
            layer.cornerRadius = cornerRadius
        }
        showPlaceholder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TVArtworkView, _: UITraitCollection) in
            if view.isShowingPlaceholder {
                view.showPlaceholder()
            } else if let artwork = view.artwork {
                view.redraw(artwork)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        redrawTask?.cancel()
    }

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
        let framing = framing
        loadTask = Task { [weak self] in
            let image = await TVImagePipeline.load(path: path, pointWidth: width, scale: scale, kind: kind)
            guard !Task.isCancelled, let self else { return }
            guard let image else {
                self.loadTask = nil
                return
            }
            let shown = await framing.render(image)
            guard !Task.isCancelled else { return }
            self.display(image, shown: shown, drawnWith: framing)
        }
    }

    /// Shows artwork from a full URL outside the Plex server, such as a poster the viewer's Seerr serves.
    func setArtwork(url: URL, placeholderSymbol: String) {
        self.placeholderSymbol = placeholderSymbol
        guard url.absoluteString != loadedPath else { return }
        reset()
        loadedPath = url.absoluteString
        let framing = framing
        loadTask = Task { [weak self] in
            let image = await RemoteImageLoader.shared.image(at: url)
            guard !Task.isCancelled, let self else { return }
            guard let image else {
                self.loadTask = nil
                return
            }
            let shown = await framing.render(image)
            guard !Task.isCancelled else { return }
            self.display(image, shown: shown, drawnWith: framing)
        }
    }

    /// Cancels any load in flight and returns to the placeholder.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        redrawTask?.cancel()
        redrawTask = nil
        loadedPath = nil
        showPlaceholder()
    }

    private func showPlaceholder() {
        isShowingPlaceholder = true
        artwork = nil
        image = TVPlaceholder.image(
            symbol: placeholderSymbol,
            size: nominalSize,
            traits: traitCollection,
            circular: shape == .circle,
            cornerRadius: shape == .rounded ? cornerRadius : 0
        )
    }

    /// Shows `shown`, the picture `used` drew in the view's shape. The original is kept only when its drawing depends on the
    /// appearance (the letterbox of an off-shape picture), so a grid holds one bitmap per card; if the appearance changed
    /// while it was drawn, it is drawn again.
    private func display(_ artwork: UIImage, shown: UIImage, drawnWith used: TVArtworkFraming) {
        isShowingPlaceholder = false
        loadTask = nil
        self.artwork = used.letterboxes(artwork) ? artwork : nil
        if UIAccessibility.isReduceMotionEnabled {
            image = shown
        } else {
            UIView.transition(with: self, duration: TVMetrics.Duration.fade, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.image = shown
            }
        }
        if self.artwork != nil, !used.letterbox.isEqual(framing.letterbox) {
            redraw(artwork)
        }
    }

    /// Draws a letterboxed picture again for the current appearance, away from the main thread.
    private func redraw(_ artwork: UIImage) {
        redrawTask?.cancel()
        let framing = framing
        redrawTask = Task { [weak self] in
            let shown = await framing.render(artwork)
            guard !Task.isCancelled, let self, self.artwork === artwork else { return }
            self.image = shown
            self.redrawTask = nil
        }
    }

    /// How a picture is drawn for this view right now; the letterbox colour depends on the appearance.
    private var framing: TVArtworkFraming {
        TVArtworkFraming(
            shape: shape,
            nominalSize: nominalSize,
            showsOffShapeWhole: showsOffShapeArtworkWhole,
            letterbox: Theme.Color.surfaceRaised.resolvedColor(with: traitCollection),
            cornerRadius: cornerRadius
        )
    }
}

/// Draws a picture in the shape of the artwork view that shows it: cropped to a circle; or, for a rounded card, cropped from
/// its centre to the card's aspect with the corners cut out, after being centred whole on the placeholder's surface when its
/// shape is too far from the card's to crop (the focus effect forbids clipping, so the letterbox is part of the image).
struct TVArtworkFraming: @unchecked Sendable {
    let shape: TVCardStyle.Shape
    let nominalSize: CGSize
    let showsOffShapeWhole: Bool
    let letterbox: UIColor
    let cornerRadius: CGFloat

    private var aspect: CGFloat { nominalSize.height / nominalSize.width }

    func draw(_ artwork: UIImage) -> UIImage {
        if shape == .circle { return artwork.circularCrop() }
        guard artwork.size.width > 0, nominalSize.width > 0 else { return artwork }
        let filled = letterboxes(artwork) ? artwork.centered(onAspect: aspect, background: letterbox) : artwork
        return filled.shaped(toAspect: aspect, cornerRadius: cornerRadius, pointWidth: nominalSize.width)
    }

    /// Whether `artwork` is drawn whole on the letterbox, whose colour follows the appearance.
    func letterboxes(_ artwork: UIImage) -> Bool {
        guard shape == .rounded, showsOffShapeWhole, artwork.size.width > 0, nominalSize.width > 0 else { return false }
        return !ArtworkAspect.fills(artwork.size.height / artwork.size.width, card: aspect)
    }

    /// `draw(_:)` away from the main thread, so a grid filling with artwork never stalls the focus animation.
    func render(_ artwork: UIImage) async -> UIImage {
        await Task.detached(priority: .userInitiated) { draw(artwork) }.value
    }
}
