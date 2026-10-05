import UIKit

/// The trailing A–Z index. It shows every other letter plus '#', but a drag resolves to the full
/// alphabet so in-between letters are reachable too.
final class AlphabetScrubberView: UIControl {
    static let displayedLetters = ["A", "C", "E", "G", "I", "K", "M", "O", "Q", "S", "U", "W", "#"]

    var onLetter: ((String) -> Void)?

    private let stack = UIStackView()
    private var labels: [UILabel] = []
    private(set) var currentLetter: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for letter in Self.displayedLetters {
            let label = UILabel()
            label.text = letter
            label.font = Theme.Font.scaled(.caption2, 10, .bold, maximum: 13)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = Theme.Color.labelTertiary
            label.textAlignment = .center
            labels.append(label)
            stack.addArrangedSubview(label)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.xs),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xs),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            widthAnchor.constraint(equalToConstant: 28),
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Jump to letter"
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setCurrentLetter(_ letter: String?) {
        guard letter != currentLetter else { return }
        currentLetter = letter
        let highlighted = letter.flatMap(Self.displayIndex(for:))
        for (index, label) in labels.enumerated() {
            label.textColor = index == highlighted ? Theme.Color.accentText : Theme.Color.labelTertiary
        }
        accessibilityValue = letter
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Theme.Space.xs, dy: 0).contains(point)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        select(at: touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        select(at: touch.location(in: self))
        return true
    }

    override func accessibilityIncrement() {
        step(by: 1)
    }

    override func accessibilityDecrement() {
        step(by: -1)
    }

    private func step(by delta: Int) {
        let letters = LibraryAlphabetIndex.letters
        let current = currentLetter.flatMap { letters.firstIndex(of: $0) } ?? -delta
        let next = min(max(current + delta, 0), letters.count - 1)
        commit(letters[next], haptic: false)
    }

    private func select(at point: CGPoint) {
        let frame = stack.frame
        guard frame.height > 0 else { return }
        let fraction = min(max((point.y - frame.minY) / frame.height, 0), 0.9999)
        let letters = LibraryAlphabetIndex.letters
        commit(letters[Int(fraction * CGFloat(letters.count))], haptic: true)
    }

    private func commit(_ letter: String, haptic: Bool) {
        guard letter != currentLetter else { return }
        setCurrentLetter(letter)
        if haptic { Haptics.selection() }
        onLetter?(letter)
    }

    /// The displayed label standing for a letter: odd letters light up the label just above them.
    private static func displayIndex(for letter: String) -> Int? {
        guard let index = LibraryAlphabetIndex.letters.firstIndex(of: letter) else { return nil }
        return letter == "#" ? displayedLetters.count - 1 : min(index / 2, displayedLetters.count - 2)
    }
}
