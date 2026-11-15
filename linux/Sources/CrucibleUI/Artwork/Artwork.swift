import Foundation
import Kiln

/// What kind of picture a path names, which decides the size the server is asked for (`TVImagePipeline.Kind`).
public enum ArtworkKind: Sendable {
    case poster, backdrop, logo
}

/// Turns a Plex artwork path into a URL for a pixel size (the server's photo transcoder); the app installs the Plex one,
/// the gallery one that reads fixtures.
@MainActor
public protocol ArtworkPipeline: AnyObject {
    func url(path: String, kind: ArtworkKind, pixelWidth: Int) -> URL?
}

@MainActor
public enum Artwork {
    public static var pipeline: ArtworkPipeline?
}

/// Where a card's picture comes from: a server path sized through the pipeline, or a full URL from elsewhere (Seerr).
public enum ArtworkSource: Hashable, Sendable {
    case path(String, ArtworkKind)
    case url(URL)

    @MainActor
    func request(pixelWidth: Int, pixelHeight: Int) -> ImageRequest? {
        switch self {
        case .path(let path, let kind):
            guard let url = Artwork.pipeline?.url(path: path, kind: kind, pixelWidth: pixelWidth) else { return nil }
            return ImageRequest(url: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        case .url(let url):
            return ImageRequest(url: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
    }
}

/// One picture a view shows: loads through the window's image store, keeps the texture, and fades it in over the
/// placeholder (instantly when it was already resident).
@MainActor
final class ArtworkSlot {
    private(set) var texture: Texture?
    private(set) var source: ArtworkSource?
    private var task: Task<Void, Never>?
    private(set) var fade = Animated(0)
    private var failedSource: ArtworkSource?
    private weak var owner: View?

    init(owner: View) {
        self.owner = owner
    }

    /// Shows `source` at `pixelSize`; the same source again is a no-op.
    func show(_ source: ArtworkSource?, pixelWidth: Int, pixelHeight: Int) {
        guard source != self.source || (texture == nil && task == nil && source != nil && failedSource != source) else { return }
        task?.cancel()
        task = nil
        self.source = source
        texture = nil
        fade.reset(0)
        guard let source, let owner, let store = owner.window?.images,
              let request = source.request(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            owner?.setNeedsDisplay()
            return
        }
        if let resident = store.cached(request) {
            texture = resident
            fade.reset(1)
            owner.setNeedsDisplay()
            return
        }
        task = Task { [weak self] in
            let texture = await store.load(request)
            guard !Task.isCancelled, let self, self.source == source else { return }
            self.task = nil
            guard let texture else {
                self.failedSource = source
                return
            }
            self.texture = texture
            self.fade.set(1, animation: .timed(duration: Durations.fade, curve: .easeInOut))
            self.owner?.startAnimating()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Advances the fade; returns whether it is still running.
    func advance(_ dt: Float) -> Bool {
        fade.advance(dt)
    }

    var opacity: Float { fade.value }
}

/// A picture filling its bounds (cropped to fill), faded in when it arrives, over the raised surface until then.
@MainActor
public final class ArtworkView: View {
    public var source: ArtworkSource? { didSet { if source != oldValue { load() } } }
    public var cornerRadius: Float = 0 { didSet { setNeedsDisplay() } }
    private lazy var slot = ArtworkSlot(owner: self)

    public init(source: ArtworkSource? = nil) {
        self.source = source
        super.init()
    }

    public override func didMoveToWindow() { load() }

    public override func layoutSubviews() { load() }

    private func load() {
        guard let window, frame.width > 0 else { return }
        slot.show(source, pixelWidth: Int((frame.width * window.scale).rounded(.up)), pixelHeight: Int((frame.height * window.scale).rounded(.up)))
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = slot.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        if slot.opacity < 1 { context.fill(bounds, radius: cornerRadius, color: Theme.current.palette.surfaceRaised) }
        if let texture = slot.texture { context.image(texture, in: bounds, radius: cornerRadius, opacity: slot.opacity) }
    }
}
