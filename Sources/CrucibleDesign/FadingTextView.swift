import UIKit

/// The lines that follow a text shown in part, fading out to nothing, so the reader sees that it goes on and where it
/// stops being theirs to read. A text shorter than the lines it may show takes only the room it needs. VoiceOver
/// passes over it: what cannot be read to the end is not read at all.
package final class FadingTextView: UIView {
    private let label = UILabel()
    private let fade = CAGradientLayer()
    private let lines: Int
    private lazy var tallest = heightAnchor.constraint(lessThanOrEqualToConstant: 0)

    package var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    /// - Parameters:
    ///   - font: The font of the text this continues.
    ///   - lines: How many lines show before the last has faded out.
    package init(font: UIFont, color: UIColor, lines: Int = 3) {
        self.lines = lines
        super.init(frame: .zero)
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.3, 1]
        layer.mask = fade

        let fitsText = bottomAnchor.constraint(equalTo: label.bottomAnchor)
        fitsText.priority = .defaultLow
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            fitsText,
            tallest,
        ])
        fitLines()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override func layoutSubviews() {
        super.layoutSubviews()
        fitLines()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        CATransaction.commit()
    }

    /// Keeps the view as tall as its lines in the font's current size, which a text size setting changes under it.
    private func fitLines() {
        let height = ceil(label.font.lineHeight * CGFloat(lines))
        if tallest.constant != height { tallest.constant = height }
    }
}
