import CrucibleDesign
@preconcurrency import UIKit

/// The loading state of a list of Trakt comments: cards with an avatar, a name and a few lines of text, as many as fill the window,
/// under the skeleton's sweeping light.
struct CommentListSkeletonConfiguration: SkeletonConfiguration, Hashable {
    func makeContentView() -> UIView & UIContentView {
        CommentListSkeletonContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> CommentListSkeletonConfiguration {
        self
    }
}

private final class CommentListSkeletonContentView: SkeletonCanvasView, UIContentView {
    var configuration: UIContentConfiguration

    init(configuration: CommentListSkeletonConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        backgroundColor = .clear
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = Theme.Space.l
        list.translatesAutoresizingMaskIntoConstraints = false
        addSubview(list)
        for index in 0..<6 {
            let card = makeCard(longest: index.isMultiple(of: 2) ? 0.96 : 0.88)
            list.addArrangedSubview(card)
        }
        let readable = list.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.readableWidth)
        let fills = list.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -Theme.Space.m * 2)
        fills.priority = .defaultHigh
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: Theme.Space.m),
            list.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            readable,
            fills,
        ])
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeCard(longest: CGFloat) -> UIView {
        let names = UIStackView()
        names.axis = .vertical
        names.alignment = .leading
        names.spacing = 6
        names.addArrangedSubview(makeBlock(width: 120, height: 13, cornerRadius: 5))
        names.addArrangedSubview(makeBlock(width: 72, height: 10, cornerRadius: 4))
        let author = UIStackView(arrangedSubviews: [makeBlock(width: 36, height: 36, cornerRadius: 18), names])
        author.spacing = Theme.Space.s
        author.alignment = .center

        let card = UIStackView(arrangedSubviews: [author])
        card.axis = .vertical
        card.alignment = .leading
        card.spacing = 9
        card.setCustomSpacing(Theme.Space.s, after: author)
        for share in [longest, 0.92, 0.97, 0.54] {
            addLine(share, to: card, height: 12)
        }
        return card
    }
}
