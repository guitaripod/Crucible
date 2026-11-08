import CrucibleDesign
import UIKit

/// The link code, one large monospaced character per glass tile. Before a code exists the tiles
/// show a dash; for VoiceOver the whole row is one element that reads the code letter by letter.
final class TVCodeTilesView: UIStackView {
    static let tileSize = CGSize(width: 168, height: 208)
    static let tileSpacing: CGFloat = 20
    /// Smaller tiles for a code too long for the four large ones, such as Trakt's eight characters.
    static let compactTileSize = CGSize(width: 96, height: 132)

    private let tiles: [Tile]
    private let hint: String

    init(length: Int = 4, hint: String = String(localized: "Enter this code at plex.tv/link")) {
        let compact = length > 4
        tiles = (0..<length).map { _ in Tile(size: compact ? Self.compactTileSize : Self.tileSize, fontSize: compact ? 76 : 124) }
        self.hint = hint
        super.init(frame: .zero)
        axis = .horizontal
        spacing = compact ? 12 : Self.tileSpacing
        distribution = .fillEqually
        tiles.forEach(addArrangedSubview)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Link code")
        accessibilityIdentifier = "onboarding.code"
        setCode(nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// Only VoiceOver needs to land here: the code is information, not a control, so for everyone
    /// else the row is not a focus stop.
    override var canBecomeFocused: Bool {
        UIAccessibility.isVoiceOverRunning
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.transform = focused ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
        })
    }

    func setCode(_ code: String?) {
        let characters = Array((code ?? "").uppercased())
        for (index, tile) in tiles.enumerated() {
            let character = index < characters.count ? String(characters[index]) : nil
            tile.setCharacter(character)
        }
        if let code {
            accessibilityValue = code.uppercased().map(String.init).joined(separator: " ")
            accessibilityHint = hint
        } else {
            accessibilityValue = String(localized: "Not ready yet")
            accessibilityHint = nil
        }
    }

    private final class Tile: UIView {
        private let effectView = Glass.effectView(fallback: .prominent)
        private let label = UILabel()

        init(size: CGSize, fontSize: CGFloat) {
            super.init(frame: .zero)
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.layer.cornerRadius = Theme.Radius.hero
            effectView.layer.cornerCurve = .continuous
            effectView.clipsToBounds = true
            addSubview(effectView)

            label.font = TVFont.mono(size: fontSize, weight: .bold)
            label.textColor = Theme.Color.label
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.translatesAutoresizingMaskIntoConstraints = false
            effectView.contentView.addSubview(label)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: size.width),
                heightAnchor.constraint(equalToConstant: size.height),
                effectView.topAnchor.constraint(equalTo: topAnchor),
                effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
                effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.centerXAnchor.constraint(equalTo: effectView.contentView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: effectView.contentView.leadingAnchor, constant: Theme.Space.s),
                label.trailingAnchor.constraint(lessThanOrEqualTo: effectView.contentView.trailingAnchor, constant: -Theme.Space.s),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func setCharacter(_ character: String?) {
            label.text = character ?? "–"
            label.alpha = character == nil ? 0.3 : 1
        }
    }
}
