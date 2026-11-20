import CrucibleCore
import CrucibleDesign
import UIKit

/// One pick of What to Watch on Apple TV: the poster with the title, what the library knows of it, and the model's
/// sentence on why it fits what was asked. A sealed pick keeps the sentence and shows nothing that names it: a lock
/// where the poster would be and, for a title, that it opens with Crucible Pro.
final class TVWatchPickSurface: TVFocusableSurface {
    static let height: CGFloat = 330
    private static let posterSize = CGSize(width: 180, height: 270)

    private struct Content {
        var title: String
        var titleFont: UIFont
        var titleColor: UIColor
        var facts: String
        var why: String
        var symbol: String
        var artworkPath: String?
    }

    init(pick: WatchPick, artworkPath: String?) {
        super.init(cornerRadius: TVMetrics.Card.cornerRadius)
        buildHierarchy(Content(
            title: pick.title.title, titleFont: Theme.Font.title3, titleColor: Theme.Color.label, facts: WatchCopy.facts(pick.title),
            why: pick.why, symbol: pick.title.kind == .show ? "tv" : "film", artworkPath: artworkPath))
    }

    init(sealed pick: WatchPick) {
        super.init(cornerRadius: TVMetrics.Card.cornerRadius)
        buildHierarchy(Content(
            title: WatchCopy.sealedTitle, titleFont: Theme.Font.subheadlineSemibold, titleColor: Theme.Color.labelSecondary, facts: "",
            why: pick.why, symbol: "lock.fill", artworkPath: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHierarchy(_ content: Content) {
        accessibilityLabel = [content.title, content.facts, content.why].filter { !$0.isEmpty }.joined(separator: ", ")
        let artwork = TVArtworkView(kind: .poster, nominalSize: Self.posterSize, placeholderSymbol: content.symbol)
        artwork.setArtwork(path: content.artworkPath, placeholderSymbol: content.symbol)
        artwork.translatesAutoresizingMaskIntoConstraints = false

        let title = Self.label(content.title, font: content.titleFont, color: content.titleColor, lines: 2)
        let facts = Self.label(content.facts, font: Theme.Font.subheadline, color: Theme.Color.labelSecondary, lines: 1)
        let why = Self.label(content.why, font: Theme.Font.body, color: Theme.Color.label, lines: 4)
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
