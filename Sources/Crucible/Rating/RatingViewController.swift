import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// Rates one title: a popover from the button on a wide window, a short sheet on a narrow one. A rating is saved
/// when the finger lifts and the sheet closes behind it; Clear Rating removes it.
final class RatingViewController: UIViewController {
    private static let popoverSize = CGSize(width: 340, height: 214)
    private static let sheetHeight: CGFloat = 244
    private static let dismissDelay: Duration = .milliseconds(380)

    private let titleText: String
    private let initial: UserRating?
    private let onSet: (UserRating?) -> Void
    private let control = StarRatingControl()
    private let valueLabel = UILabel()
    private let clearButton = UIButton(configuration: .plain())
    private var dismissTask: Task<Void, Never>?

    init(title: String, rating: UserRating?, onSet: @escaping (UserRating?) -> Void) {
        self.titleText = title
        self.initial = rating
        self.onSet = onSet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { dismissTask?.cancel() }

    static func present(from host: UIViewController, source: UIView, title: String, rating: UserRating?, onSet: @escaping (UserRating?) -> Void) {
        let controller = RatingViewController(title: title, rating: rating, onSet: onSet)
        if host.traitCollection.horizontalSizeClass == .regular {
            controller.modalPresentationStyle = .popover
            controller.preferredContentSize = popoverSize
            controller.popoverPresentationController?.sourceView = source
            controller.popoverPresentationController?.sourceRect = source.bounds
            controller.popoverPresentationController?.permittedArrowDirections = [.up, .down]
        } else {
            controller.modalPresentationStyle = .pageSheet
            if let sheet = controller.sheetPresentationController {
                sheet.detents = [.custom { _ in sheetHeight }]
                sheet.prefersGrabberVisible = true
            }
        }
        host.present(controller, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        view.tintColor = Theme.Color.accent

        let header = UILabel()
        header.text = titleText
        header.font = Theme.Font.headline
        header.textColor = Theme.Color.label
        header.textAlignment = .center
        header.numberOfLines = 2
        header.adjustsFontForContentSizeCategory = true
        header.accessibilityTraits = .header

        valueLabel.font = Theme.Font.title2
        valueLabel.textColor = Theme.Color.label
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.isAccessibilityElement = false

        control.setRating(initial)
        control.addAction(UIAction { [weak self] _ in self?.updateValue() }, for: .valueChanged)
        control.addAction(UIAction { [weak self] _ in self?.commit() }, for: .primaryActionTriggered)

        var clear = UIButton.Configuration.plain()
        clear.title = UserRatingCopy.clear
        clear.baseForegroundColor = Theme.Color.destructive
        clear.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.subheadlineSemibold
            return outgoing
        }
        clearButton.configuration = clear
        clearButton.isPointerInteractionEnabled = true
        clearButton.addAction(UIAction { [weak self] _ in self?.clearRating() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [header, control, valueLabel, clearButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.s
        stack.setCustomSpacing(Theme.Space.m, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.l),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        updateValue()
    }

    private func updateValue() {
        let rating = control.rating
        valueLabel.text = rating.map { "\($0.text) / \(UserRating.maxStars)" } ?? String(localized: "Not rated yet", comment: "Shown under the star rating control while the title has no rating")
        valueLabel.textColor = rating == nil ? Theme.Color.labelSecondary : Theme.Color.label
        clearButton.isHidden = rating == nil
    }

    private func commit() {
        guard let rating = control.rating else { return }
        Haptics.success()
        onSet(rating)
        dismissSoon()
    }

    private func clearRating() {
        Haptics.light()
        control.setRating(nil, animated: true)
        updateValue()
        onSet(nil)
        dismissSoon()
    }

    private func dismissSoon() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }
}
