import UIKit

/// The card that sits over the last frame of the episode before while the next one is being resolved: the
/// player never goes black or empty between episodes, so it says what is happening instead.
@MainActor
final class AdvanceIndicator {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    init() {
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.clipsToBounds = true
        spinner.color = .white
        spinner.startAnimating()
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -10),
        ])
    }

    func show(in host: UIView, title: String) {
        label.text = title
        blur.alpha = 0
        host.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            blur.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            blur.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
            blur.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24),
        ])
        prepareAccessibility()
        UIView.animate(withDuration: 0.2) { self.blur.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: title)
    }

    func hide() {
        UIView.animate(withDuration: 0.2, animations: { self.blur.alpha = 0 }) { _ in
            self.blur.removeFromSuperview()
        }
    }

    /// VoiceOver reads the card as one element naming the episode that is about to play.
    private func prepareAccessibility() {
        spinner.isAccessibilityElement = false
        blur.isAccessibilityElement = true
        blur.accessibilityLabel = label.text
    }
}
