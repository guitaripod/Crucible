import CrucibleDesign
import UIKit

/// The full synopsis in a glass panel over the dimmed screen. Menu or Close dismisses it and focus
/// returns to the More button that opened it.
final class TVSynopsisViewController: UIViewController {
    private let titleText: String
    private let bodyText: String
    private let panel = Glass.effectView(fallback: .regular)
    private let textView = UITextView()
    private var textHeight: NSLayoutConstraint?
    private lazy var closeButton = TVButton.make(.glass, title: "Close") { [weak self] in
        self?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    init(title: String, text: String) {
        titleText = title
        bodyText = text
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas.withAlphaComponent(0.72)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = Theme.Radius.l
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        view.addSubview(panel)

        let heading = UILabel()
        heading.font = Theme.Font.title3
        heading.textColor = Theme.Color.label
        heading.text = titleText
        heading.numberOfLines = 2
        heading.accessibilityTraits = .header

        textView.font = Theme.Font.body
        textView.textColor = Theme.Color.label
        textView.backgroundColor = .clear
        textView.text = bodyText
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = "detail.synopsis.text"
        textView.accessibilityLabel = bodyText

        let stack = UIStackView(arrangedSubviews: [heading, textView, closeButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stack)
        closeButton.accessibilityIdentifier = "detail.synopsis.close"

        let inset = Theme.Space.xl
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 1100),
            panel.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -inset),
            textView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let height = textView.heightAnchor.constraint(equalToConstant: 120)
        height.isActive = true
        textHeight = height
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitText()
    }

    /// Sizes the text to its content up to what the screen leaves; longer text scrolls.
    private func fitText() {
        let width = textView.bounds.width
        guard width > 0 else { return }
        let wanted = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let available = view.safeAreaLayoutGuide.layoutFrame.height - 2 * Theme.Space.xl - 2 * Theme.Space.l - TVMetrics.Control.primaryHeight - 160
        let height = min(wanted, max(available, 240))
        textView.isScrollEnabled = wanted > height
        if textHeight?.constant != height {
            textHeight?.constant = height
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [closeButton] }
}
