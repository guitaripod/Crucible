import CrucibleDesign
import UIKit

/// A small glass label in the corner of the picture naming the jump a press-and-hold just made. The system player shows its
/// transport bar only for moves it makes itself, so without this a hold would move the picture with nothing on screen to say
/// where it went. It fades in, stays a moment and fades out; a jump made meanwhile replaces it.
@MainActor
final class TVPlayerJumpIndicator: UIView {
    private static let shown: Duration = .milliseconds(1600)

    private let symbol = UIImageView()
    private let label = UILabel()
    private var hideTask: Task<Void, Never>?

    /// Adds the indicator to the bottom corner of `overlay`, where the Up Next card also sits.
    static func install(in overlay: UIView) -> TVPlayerJumpIndicator {
        let indicator = TVPlayerJumpIndicator()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor),
            indicator.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor),
        ])
        return indicator
    }

    private init() {
        super.init(frame: .zero)
        alpha = 0
        isUserInteractionEnabled = false
        overrideUserInterfaceStyle = .dark
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, symbol name: String) {
        label.text = text
        symbol.image = UIImage(systemName: name)
        UIAccessibility.post(notification: .announcement, argument: text)
        hideTask?.cancel()
        TVMotion.animate { self.alpha = 1 }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.shown)
            guard !Task.isCancelled, let self else { return }
            TVMotion.animate { self.alpha = 0 }
        }
    }

    private func build() {
        let glass = Glass.effectView(fallback: .dark)
        glass.clipsToBounds = true
        glass.layer.cornerRadius = Theme.Radius.l
        glass.layer.cornerCurve = .continuous
        glass.translatesAutoresizingMaskIntoConstraints = false

        symbol.tintColor = Theme.Color.onArt
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Theme.Font.headline)
        symbol.contentMode = .scaleAspectFit
        label.font = Theme.Font.headline
        label.textColor = Theme.Color.onArt

        let row = UIStackView(arrangedSubviews: [symbol, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.s
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glass)
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: Theme.Space.s),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Theme.Space.s),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Theme.Space.m),
        ])
    }
}
