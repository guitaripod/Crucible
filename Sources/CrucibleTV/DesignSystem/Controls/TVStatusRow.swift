import CrucibleDesign
import UIKit

/// A quiet status line with an optional spinner: "Connecting to Marcus-PC…", "Waiting for approval…".
/// A new non-empty text is announced to VoiceOver.
final class TVStatusRow: UIStackView {
    enum Tone {
        case neutral
        case error
    }

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = Theme.Space.s
        label.font = Theme.Font.callout
        label.numberOfLines = 0
        spinner.hidesWhenStopped = true
        addArrangedSubview(spinner)
        addArrangedSubview(label)
        isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// Shows `text` (hides the row for nil or empty), with a spinner while `isBusy`.
    func show(_ text: String?, isBusy: Bool = false, tone: Tone = .neutral) {
        let value = text ?? ""
        let changed = value != (label.text ?? "")
        label.text = value
        label.textColor = tone == .error ? Theme.Color.destructive : Theme.Color.labelSecondary
        if isBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
        isHidden = value.isEmpty
        if changed, !value.isEmpty {
            UIAccessibility.post(notification: .announcement, argument: value)
        }
    }
}
