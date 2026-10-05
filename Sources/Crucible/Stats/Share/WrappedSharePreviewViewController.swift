@preconcurrency import UIKit

/// Shows the poster exactly as it will be shared, lets the person pick the format, then hands the
/// image to the system share sheet.
final class WrappedSharePreviewViewController: UIViewController {
    private let content: WrappedShareContent
    private let renderer = WrappedShareCardRenderer()
    private var rendered = [WrappedShareCardRenderer.Format: UIImage]()
    private var format = WrappedShareCardRenderer.Format.story

    private let formatControl = UISegmentedControl(items: WrappedShareCardRenderer.Format.allCases.map(\.title))
    private let stage = UIView()
    private let frameView = UIView()
    private let imageView = UIImageView()
    private let shareButton = ThemeButton.primary(title: "Share", symbol: "square.and.arrow.up")
    private var aspectConstraint: NSLayoutConstraint?

    init(content: WrappedShareContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        setupFormatControl()
        setupStage()
        setupShareButton()
        layoutScreen()
        show(.story, animated: false)
    }

    private func setupFormatControl() {
        formatControl.selectedSegmentIndex = format.rawValue
        formatControl.addAction(UIAction { [weak self] _ in
            guard let self, let next = WrappedShareCardRenderer.Format(rawValue: formatControl.selectedSegmentIndex) else { return }
            Haptics.selection()
            show(next, animated: true)
        }, for: .valueChanged)
    }

    private func setupStage() {
        frameView.layer.cornerRadius = 28
        frameView.layer.cornerCurve = .continuous
        frameView.layer.shadowColor = UIColor.black.cgColor
        frameView.layer.shadowOpacity = 0.35
        frameView.layer.shadowRadius = 28
        frameView.layer.shadowOffset = CGSize(width: 0, height: 14)
        frameView.translatesAutoresizingMaskIntoConstraints = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 28
        imageView.layer.cornerCurve = .continuous
        imageView.layer.borderWidth = 1
        imageView.layer.borderColor = Theme.Color.artHairline.cgColor
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = content.summary
        imageView.accessibilityTraits = .image
        imageView.translatesAutoresizingMaskIntoConstraints = false

        frameView.addSubview(imageView)
        stage.addSubview(frameView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: frameView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            frameView.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            frameView.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor),
            frameView.heightAnchor.constraint(lessThanOrEqualTo: stage.heightAnchor),
        ])
        let fillHeight = frameView.heightAnchor.constraint(equalTo: stage.heightAnchor)
        fillHeight.priority = UILayoutPriority(750)
        let fillWidth = frameView.widthAnchor.constraint(equalTo: stage.widthAnchor)
        fillWidth.priority = UILayoutPriority(749)
        NSLayoutConstraint.activate([fillHeight, fillWidth])
    }

    private func setupShareButton() {
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .primaryActionTriggered)
    }

    private func layoutScreen() {
        navigationItem.titleView = formatControl
        formatControl.widthAnchor.constraint(equalToConstant: 220).isActive = true
        [stage, shareButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            shareButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Space.l),
            shareButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Space.l),
            shareButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Theme.Space.m),
            shareButton.heightAnchor.constraint(equalToConstant: Theme.Size.primaryButtonHeight),

            stage.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.Space.s),
            stage.bottomAnchor.constraint(equalTo: shareButton.topAnchor, constant: -Theme.Space.m),
            stage.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Space.l),
            stage.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Space.l),
        ])
    }

    func select(_ next: WrappedShareCardRenderer.Format) {
        formatControl.selectedSegmentIndex = next.rawValue
        show(next, animated: false)
    }

    private func show(_ next: WrappedShareCardRenderer.Format, animated: Bool) {
        format = next
        let image = poster(for: next)
        aspectConstraint?.isActive = false
        let ratio = next.size.width / next.size.height
        let aspect = frameView.widthAnchor.constraint(equalTo: frameView.heightAnchor, multiplier: ratio)
        aspect.isActive = true
        aspectConstraint = aspect
        let apply = {
            self.imageView.image = image
            self.view.layoutIfNeeded()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.transition(with: frameView, duration: 0.25, options: .transitionCrossDissolve, animations: apply)
    }

    private func poster(for format: WrappedShareCardRenderer.Format) -> UIImage {
        if let cached = rendered[format] { return cached }
        let image = renderer.render(content, format: format)
        rendered[format] = image
        return image
    }

    private func share() {
        Haptics.light()
        let item = WrappedShareItem(image: poster(for: format), title: content.shareTitle)
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }
}
