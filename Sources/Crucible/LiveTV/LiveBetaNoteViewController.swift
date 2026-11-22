import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// What the Beta tag beside Live TV opens: a popover from the tag (a sheet where there is no room for one) saying what Live
/// TV does today, with Send Feedback and Got It.
final class LiveBetaNoteViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.surface
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.l),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.l),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.l),
        ])
        let tag = BetaTag.button(title: LiveTVCopy.beta, action: UIAction { _ in })
        tag.isUserInteractionEnabled = false
        tag.isAccessibilityElement = false
        let tagRow = UIStackView(arrangedSubviews: [tag, UIView()])
        stack.addArrangedSubview(tagRow)
        stack.addArrangedSubview(label(LiveTVCopy.betaTitle, font: Theme.Font.title3, color: Theme.Color.label, header: true))
        stack.addArrangedSubview(label(LiveTVCopy.betaIntro, font: Theme.Font.body, color: Theme.Color.labelSecondary))
        for point in LiveTVCopy.betaPoints {
            stack.addArrangedSubview(pointRow(symbol: point.symbol, text: point.text))
        }
        stack.addArrangedSubview(label(LiveTVCopy.betaFooter, font: Theme.Font.footnote, color: Theme.Color.labelSecondary))
        var feedback = UIButton.Configuration.gray()
        feedback.title = LiveTVCopy.betaFeedback
        feedback.cornerStyle = .capsule
        var dismiss = UIButton.Configuration.filled()
        dismiss.title = LiveTVCopy.betaDismiss
        dismiss.baseBackgroundColor = Theme.Color.accent
        dismiss.baseForegroundColor = Theme.Color.onAccent
        dismiss.cornerStyle = .capsule
        let feedbackButton = UIButton(configuration: feedback, primaryAction: UIAction { [weak self] _ in self?.sendFeedback() })
        feedbackButton.accessibilityIdentifier = "livetv.beta.feedback"
        let dismissButton = UIButton(configuration: dismiss, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        dismissButton.accessibilityIdentifier = "livetv.beta.dismiss"
        let buttons = UIStackView(arrangedSubviews: [feedbackButton, dismissButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Space.s
        buttons.distribution = .fillEqually
        stack.setCustomSpacing(Theme.Space.l, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(buttons)
        view.accessibilityIdentifier = "livetv.beta.note"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = min(view.window?.bounds.width ?? 380, 380)
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: width - Theme.Space.l * 2, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let size = CGSize(width: width, height: fitting.height + Theme.Space.l * 2)
        if preferredContentSize != size { preferredContentSize = size }
    }

    private func label(_ text: String, font: UIFont, color: UIColor, header: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        if header { label.accessibilityTraits = .header }
        return label
    }

    private func pointRow(symbol: String, text: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.tintColor = Theme.Color.accent
        image.contentMode = .center
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Theme.Font.subheadlineSemibold)
        image.backgroundColor = Theme.Color.accentTint
        image.layer.cornerRadius = Theme.Radius.xs
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 30), image.heightAnchor.constraint(equalToConstant: 30)])
        let row = UIStackView(arrangedSubviews: [image, label(text, font: Theme.Font.subheadline, color: Theme.Color.label)])
        row.axis = .horizontal
        row.spacing = Theme.Space.s
        row.alignment = .center
        row.isAccessibilityElement = true
        row.accessibilityLabel = text
        return row
    }

    private func sendFeedback() {
        guard let url = LiveTVCopy.feedbackURL else { return }
        UIApplication.shared.open(url)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .formSheet : .none
    }
}
