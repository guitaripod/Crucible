import CrucibleDesign
import UIKit

/// A cast or crew card: a 200pt circle with the name and role under it. The circle is the person's
/// photo, or a monogram (initials on the person's stable gradient, like the iPhone) when Plex has none.
/// Neither version is selectable, so the card is not announced as a button.
///
/// TODO(ds): the design system's person card only offers a symbol placeholder; once it can take a
/// monogram this cell can become a `TVPersonCell` again.
final class TVDetailPersonCell: UICollectionViewCell {
    private static let style = TVCardStyle.person

    private let photo = TVArtworkView(
        kind: .poster,
        nominalSize: TVDetailPersonCell.style.artworkSize,
        shape: .circle,
        placeholderSymbol: "person.fill"
    )
    private let monogramView = UIImageView()
    private let nameLabel = UILabel()
    private let roleLabel = UILabel()
    private var photoCaptionConstraint: NSLayoutConstraint?
    private var monogramCaptionConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        monogramView.adjustsImageWhenAncestorFocused = true
        monogramView.masksFocusEffectToContents = true
        monogramView.contentMode = .scaleAspectFill

        nameLabel.font = TVFont.cardTitle
        nameLabel.textColor = Theme.Color.label
        roleLabel.font = TVFont.cardSubtitle
        roleLabel.textColor = Theme.Color.labelSecondary
        [nameLabel, roleLabel].forEach {
            $0.textAlignment = .center
            $0.lineBreakMode = .byTruncatingTail
        }

        let captions = UIStackView(arrangedSubviews: [nameLabel, roleLabel])
        captions.axis = .vertical
        captions.spacing = TVMetrics.Card.captionLabelSpacing
        [photo, monogramView, captions].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        let size = Self.style.artworkSize
        let photoCaption = captions.topAnchor.constraint(equalTo: photo.focusedFrameGuide.bottomAnchor, constant: TVMetrics.Card.captionSpacing)
        let monogramCaption = captions.topAnchor.constraint(equalTo: monogramView.focusedFrameGuide.bottomAnchor, constant: TVMetrics.Card.captionSpacing)
        photoCaptionConstraint = photoCaption
        monogramCaptionConstraint = monogramCaption
        var constraints = [
            captions.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            captions.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            photoCaption,
        ]
        for artwork in [photo, monogramView] {
            constraints += [
                artwork.topAnchor.constraint(equalTo: contentView.topAnchor),
                artwork.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                artwork.widthAnchor.constraint(equalToConstant: size.width),
                artwork.heightAnchor.constraint(equalToConstant: size.height),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: TVDetailPersonCell, _: UITraitCollection) in
            cell.refreshMonogram()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var person: TVDetailPerson?

    static func registration() -> UICollectionView.CellRegistration<TVDetailPersonCell, TVDetailPerson> {
        UICollectionView.CellRegistration<TVDetailPersonCell, TVDetailPerson> { cell, _, person in
            cell.configure(with: person)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        photo.reset()
    }

    func configure(with person: TVDetailPerson) {
        self.person = person
        nameLabel.text = person.name
        roleLabel.text = person.role
        roleLabel.isHidden = (person.role ?? "").isEmpty
        accessibilityLabel = [person.name, person.role].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")

        let hasPhoto = !(person.photoPath ?? "").isEmpty
        photo.isHidden = !hasPhoto
        monogramView.isHidden = hasPhoto
        photoCaptionConstraint?.isActive = hasPhoto
        monogramCaptionConstraint?.isActive = !hasPhoto
        if hasPhoto {
            photo.setArtwork(path: person.photoPath, placeholderSymbol: "person.fill")
        } else {
            photo.reset()
            refreshMonogram()
        }
    }

    private func refreshMonogram() {
        guard let person, (person.photoPath ?? "").isEmpty else { return }
        monogramView.image = TVMonogramImage.image(name: person.name, diameter: Self.style.artworkSize.width, traits: traitCollection)
    }
}

/// Renders the shared monogram into a transparent circle, so the system focus effect can lift it like a photo.
@MainActor
enum TVMonogramImage {
    private static var cache: [String: UIImage] = [:]

    static func image(name: String, diameter: CGFloat, traits: UITraitCollection) -> UIImage {
        let key = "\(name)|\(Int(diameter))|\(traits.userInterfaceStyle.rawValue)"
        if let cached = cache[key] { return cached }
        var rendered = UIImage()
        traits.performAsCurrent {
            let view = MonogramView(diameter: diameter, font: Theme.Font.title1)
            view.configure(name: name, fill: .person)
            view.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            view.layoutIfNeeded()
            rendered = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
                view.layer.render(in: context.cgContext)
            }
        }
        cache[key] = rendered
        return rendered
    }
}
