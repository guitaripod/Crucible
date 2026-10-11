import CrucibleDesign
import UIKit

/// The link code, one large monospaced character per glass tile. Before a code exists the tiles
/// show a dash; for VoiceOver the whole row is one element that reads the code letter by letter.
final class TVCodeTilesView: UIStackView {
    static let tileSize = CGSize(width: 168, height: 208)
    static let tileSpacing: CGFloat = 20
    private static let codeLength = 4

    private let tiles: [Tile]

    override init(frame: CGRect) {
        tiles = (0..<Self.codeLength).map { _ in Tile() }
        super.init(frame: frame)
        axis = .horizontal
        spacing = Self.tileSpacing
        distribution = .fillEqually
        tiles.forEach(addArrangedSubview)
        isAccessibilityElement = true
        accessibilityLabel = "Link code"
        accessibilityIdentifier = "onboarding.code"
        setCode(nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func setCode(_ code: String?) {
        let characters = Array((code ?? "").uppercased())
        for (index, tile) in tiles.enumerated() {
            let character = index < characters.count ? String(characters[index]) : nil
            tile.setCharacter(character)
        }
        if let code {
            accessibilityValue = code.uppercased().map(String.init).joined(separator: " ")
            accessibilityHint = "Enter this code at plex.tv/link"
        } else {
            accessibilityValue = "Not ready yet"
            accessibilityHint = nil
        }
    }

    private final class Tile: UIView {
        private let effectView = Glass.effectView(fallback: .prominent)
        private let label = UILabel()

        init() {
            super.init(frame: .zero)
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.layer.cornerRadius = Theme.Radius.hero
            effectView.layer.cornerCurve = .continuous
            effectView.clipsToBounds = true
            addSubview(effectView)

            label.font = UIFont.monospacedSystemFont(ofSize: 124, weight: .bold)
            label.textColor = Theme.Color.label
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.translatesAutoresizingMaskIntoConstraints = false
            effectView.contentView.addSubview(label)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: TVCodeTilesView.tileSize.width),
                heightAnchor.constraint(equalToConstant: TVCodeTilesView.tileSize.height),
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
