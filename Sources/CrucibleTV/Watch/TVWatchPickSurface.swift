import CrucibleCore
import CrucibleDesign
import UIKit

/// One pick of What to Watch on Apple TV: the poster with the title, what the library knows of it, and the model's
/// sentence on why it fits what was asked.
final class TVWatchPickSurface: TVFocusableSurface {
    static let height: CGFloat = 330
    private static let posterSize = CGSize(width: 180, height: 270)

    init(pick: WatchPick, artworkPath: String?) {
        super.init(cornerRadius: TVMetrics.Card.cornerRadius)
        accessibilityLabel = [pick.title.title, WatchCopy.facts(pick.title), pick.why].filter { !$0.isEmpty }.joined(separator: ", ")
        buildHierarchy(pick, artworkPath: artworkPath)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHierarchy(_ pick: WatchPick, artworkPath: String?) {
        let symbol = pick.title.kind == .show ? "tv" : "film"
        let artwork = TVArtworkView(kind: .poster, nominalSize: Self.posterSize, placeholderSymbol: symbol)
        artwork.setArtwork(path: artworkPath, placeholderSymbol: symbol)
        artwork.translatesAutoresizingMaskIntoConstraints = false

        let title = Self.label(pick.title.title, font: Theme.Font.title3, color: Theme.Color.label, lines: 2)
        let facts = Self.label(WatchCopy.facts(pick.title), font: Theme.Font.subheadline, color: Theme.Color.labelSecondary, lines: 1)
        let why = Self.label(pick.why, font: Theme.Font.body, color: Theme.Color.label, lines: 4)
        let text = UIStackView(arrangedSubviews: [title, facts, why])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = Theme.Space.xxs
        text.setCustomSpacing(Theme.Space.s, after: facts)

        let row = UIStackView(arrangedSubviews: [artwork, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.l
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: Self.posterSize.width),
            artwork.heightAnchor.constraint(equalToConstant: Self.posterSize.height),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.l),
        ])
    }

    private static func label(_ text: String, font: UIFont, color: UIColor, lines: Int) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        label.isHidden = text.isEmpty
        return label
    }
}
