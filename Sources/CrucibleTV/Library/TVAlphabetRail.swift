import CrucibleDesign
import UIKit

/// The A-Z index on the trailing edge: one focusable letter for every letter the library has items
/// for. Selecting a letter reports it; the current letter (the one under the grid focus) is lit.
final class TVAlphabetRail: UIView {
    static let width: CGFloat = 80
    /// The strip behind the rail where artwork fades out, starting just past the grid's right edge.
    static let fadeWidth: CGFloat = 76
    private static let letterHeight: CGFloat = 32
    private static let letterWidth: CGFloat = 56

    var onSelect: (@MainActor (String) -> Void)?

    private let stack = UIStackView()
    private var buttons: [String: UIButton] = [:]
    private(set) var letters: [String] = []

    var currentLetter: String? {
        didSet {
            guard currentLetter != oldValue else { return }
            buttons.values.forEach { $0.setNeedsUpdateConfiguration() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        accessibilityIdentifier = "tv.library.rail"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The height the letters need, so the owner can centre the rail.
    var preferredHeight: CGFloat {
        CGFloat(letters.count) * Self.letterHeight
    }

    func update(letters: [String]) {
        guard letters != self.letters else { return }
        self.letters = letters
        buttons.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for letter in letters {
            let button = makeButton(for: letter)
            buttons[letter] = button
            stack.addArrangedSubview(button)
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.width, height: preferredHeight)
    }

    private func makeButton(for letter: String) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "tv.library.rail.\(letter)"
        button.accessibilityLabel = "Jump to \(letter == "#" ? "numbers and symbols" : letter)"
        button.configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            var configuration = UIButton.Configuration.plain()
            configuration.title = letter
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = Theme.Font.scaled(.caption1, 25, .semibold, maximum: 25)
                return outgoing
            }
            configuration.cornerStyle = .capsule
            if !button.isFocused {
                configuration.baseForegroundColor = self.currentLetter == letter ? Theme.Color.accentText : Theme.Color.labelSecondary
            }
            button.configuration = configuration
        }
        button.addAction(UIAction { [weak self] _ in self?.onSelect?(letter) }, for: .primaryActionTriggered)
        button.widthAnchor.constraint(equalToConstant: Self.letterWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.letterHeight).isActive = true
        return button
    }
}
