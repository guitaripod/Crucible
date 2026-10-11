import CrucibleDesign
import UIKit

/// Full-screen artwork behind a screen, with the three scrims that keep text, shelves and the tab
/// bar legible over any picture. `show(path:)` debounces rapid focus changes and cross-fades; the
/// `dimming` level lets a scroll view push the picture back as its content rises over it.
///
/// Scrims are tinted with the canvas colour rather than black, so in Light appearance the picture
/// fades into the light canvas and dark text stays readable.
final class TVBackdropView: UIView {
    var dimming: CGFloat = 0 {
        didSet {
            let clamped = max(0, min(1, dimming))
            dimView.alpha = clamped * TVMetrics.Backdrop.maximumDimming
        }
    }

    private var pictures: [UIImageView] = []
    private let dimView = UIView()
    private let textScrim = TVGradientView()
    private let bottomScrim = TVGradientView()
    private let topScrim = TVGradientView()
    private var pendingTask: Task<Void, Never>?
    private var requestedPath: String?
    private var shownPath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.canvas
        clipsToBounds = true
        isUserInteractionEnabled = false
        buildScrims()
        dimView.backgroundColor = Theme.Color.canvas
        dimView.alpha = 0
        addSubview(dimView)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { pendingTask?.cancel() }

    private func buildScrims() {
        let canvas = Theme.Color.canvas
        textScrim.setColors(
            [canvas.withAlphaComponent(0.96), canvas.withAlphaComponent(0.78), canvas.withAlphaComponent(0)],
            locations: [0, 0.42, 0.78],
            from: CGPoint(x: 0, y: 0.5),
            to: CGPoint(x: 1, y: 0.5)
        )
        bottomScrim.setColors(
            [canvas.withAlphaComponent(0), canvas.withAlphaComponent(0.7), canvas.withAlphaComponent(1)],
            locations: [0.35, 0.72, 1],
            from: CGPoint(x: 0.5, y: 0),
            to: CGPoint(x: 0.5, y: 1)
        )
        topScrim.setColors(
            [canvas.withAlphaComponent(0.85), canvas.withAlphaComponent(0)],
            from: CGPoint(x: 0.5, y: 0),
            to: CGPoint(x: 0.5, y: 1)
        )
        [textScrim, bottomScrim, topScrim].forEach(addSubview)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pictures.forEach { $0.frame = bounds }
        textScrim.frame = bounds
        bottomScrim.frame = bounds
        dimView.frame = bounds
        topScrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TVMetrics.Backdrop.topScrimHeight)
    }

    /// Cross-fades to the artwork at `path` after `TVMetrics.Duration.backdropDebounce` of stillness;
    /// a newer call supersedes an older one that has not finished loading. A nil path fades to canvas.
    func show(path: String?) {
        guard path != requestedPath else { return }
        requestedPath = path
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TVMetrics.Duration.backdropDebounce))
            guard !Task.isCancelled, let self else { return }
            await self.load(path)
        }
    }

    /// Shows `image` at once, for callers that already hold the picture (a detail screen's first paint).
    func show(image: UIImage?, animated: Bool = false) {
        pendingTask?.cancel()
        requestedPath = nil
        shownPath = nil
        apply(image, animated: animated)
    }

    private func load(_ path: String?) async {
        guard let path else {
            apply(nil, animated: true)
            shownPath = nil
            return
        }
        guard path != shownPath else { return }
        let scale = max(traitCollection.displayScale, 1)
        let width = max(bounds.width, 1)
        guard let image = await TVImagePipeline.load(path: path, pointWidth: width, scale: scale, kind: .backdrop) else { return }
        guard !Task.isCancelled, requestedPath == path else { return }
        shownPath = path
        apply(image, animated: true)
    }

    /// Each new picture is laid on top of the old ones and faded in; once it is opaque the pictures
    /// beneath it are dropped, so overlapping fades never flash or leave stale layers behind.
    private func apply(_ image: UIImage?, animated: Bool) {
        guard let image else {
            fadeOutPictures(animated: animated)
            return
        }
        let picture = UIImageView(image: image)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.frame = bounds
        if let top = pictures.last {
            insertSubview(picture, aboveSubview: top)
        } else {
            insertSubview(picture, at: 0)
        }
        pictures.append(picture)
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            dropPictures(below: picture)
            return
        }
        picture.alpha = 0
        UIView.animate(withDuration: TVMetrics.Duration.backdropFade, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            picture.alpha = 1
        } completion: { [weak self] _ in
            self?.dropPictures(below: picture)
        }
    }

    private func dropPictures(below picture: UIImageView) {
        guard let index = pictures.firstIndex(of: picture) else { return }
        pictures[..<index].forEach { $0.removeFromSuperview() }
        pictures.removeSubrange(..<index)
    }

    private func fadeOutPictures(animated: Bool) {
        let outgoing = pictures
        pictures.removeAll()
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            outgoing.forEach { $0.removeFromSuperview() }
            return
        }
        UIView.animate(withDuration: TVMetrics.Duration.backdropFade, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            outgoing.forEach { $0.alpha = 0 }
        } completion: { _ in
            outgoing.forEach { $0.removeFromSuperview() }
        }
    }
}
