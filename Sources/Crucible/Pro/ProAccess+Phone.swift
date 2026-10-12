import CrucibleCore
import CrucibleDesign
import UIKit

extension ProAccess {
    /// Locked controls carry a lock glyph only on a free install of the App Store build: Pro installs and source builds never see one.
    var showsLocks: Bool { isStoreBacked && !isPro }
}

/// The lock glyph drawn on locked controls, and the one image recipe that puts it next to another symbol.
@MainActor
enum ProLock {
    static let symbolName = "lock.fill"

    static func image(pointSize: CGFloat = 12) -> UIImage? {
        UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
    }

    /// A template image of `symbol` with a small lock at its lower trailing corner, for bar buttons that cannot hold two images.
    static func badged(symbol: String, pointSize: CGFloat = 17) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let base = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(.black, renderingMode: .alwaysOriginal),
              let lock = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize * 0.55, weight: .bold))?
                .withTintColor(.black, renderingMode: .alwaysOriginal)
        else { return nil }
        let padding = pointSize * 0.3
        let size = CGSize(width: base.size.width + padding, height: base.size.height + padding)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            base.draw(at: .zero)
            let lockOrigin = CGPoint(x: size.width - lock.size.width, y: size.height - lock.size.height)
            let halo = CGRect(origin: lockOrigin, size: lock.size).insetBy(dx: -2, dy: -2)
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: halo)
            context.cgContext.setBlendMode(.normal)
            lock.draw(at: lockOrigin)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// Keeps a view controller in step with Pro turning on or off, and removes the observer when it goes away.
@MainActor
final class ProObservation {
    private var token: UUID?

    init(_ handler: @escaping @MainActor () -> Void) {
        token = ProAccess.shared.observe { _ in handler() }
    }

    deinit {
        guard let token else { return }
        Task { @MainActor in ProAccess.shared.stopObserving(token) }
    }
}
