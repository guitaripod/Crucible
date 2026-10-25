import CrucibleDesign
@preconcurrency import UIKit

/// The frame the demo's two sheets share: the crystal, a title and a body over scrolling content, with the actions pinned under it so
/// they stay reachable at every text size.
class DemoSheetViewController: UIViewController {
    let contentStack = UIStackView()
    let actionStack = UIStackView()

    private let scrollView = UIScrollView()
    private let footerContainer = UIView()
    private let glyph = CrystalGlyphView()

    init(detents: [UISheetPresentationController.Detent]) {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        preferredContentSize = Self.largeWindowSize
        if let sheet = sheetPresentationController {
            sheet.detents = detents
            sheet.prefersGrabberVisible = true
            if #unavailable(iOS 26.0) {
                sheet.preferredCornerRadius = 32
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// On a large iPad window the sheet is a centred card this size; a phone or a narrow window shows it at its detents.
    static let largeWindowSize = CGSize(width: 600, height: 820)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        view.tintColor = Theme.Color.accent
        buildLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !UIAccessibility.isReduceMotionEnabled { glyph.startBreathing() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    func addHeader(title: String, body: String) {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 64),
            glyph.heightAnchor.constraint(equalToConstant: 64),
        ])
        let glyphRow = UIStackView(arrangedSubviews: [UIView(), glyph, UIView()])
        glyphRow.distribution = .equalCentering

        let titleLabel = makeLabel(title, font: Theme.Font.title1, color: Theme.Color.label, alignment: .center)
        titleLabel.accessibilityTraits = .header
        let bodyLabel = makeLabel(body, font: Theme.Font.callout, color: Theme.Color.labelSecondary, alignment: .center)

        let header = UIStackView(arrangedSubviews: [glyphRow, titleLabel, bodyLabel])
        header.axis = .vertical
        header.spacing = 6
        header.setCustomSpacing(10, after: glyphRow)
        contentStack.addArrangedSubview(header)
    }

    func makeLabel(_ text: String, font: UIFont, color: UIColor, alignment: NSTextAlignment = .natural) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.textAlignment = alignment
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    func addAction(_ button: UIButton) {
        actionStack.addArrangedSubview(button)
    }

    func makeLinkButton(title: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = Theme.Color.accentText
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.buttonLabel
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.isPointerInteractionEnabled = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget).isActive = true
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }

    private func buildLayout() {
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.axis = .vertical
        contentStack.spacing = 18
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 28, left: 20, bottom: 24, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        actionStack.axis = .vertical
        actionStack.spacing = 4
        actionStack.isLayoutMarginsRelativeArrangement = true
        actionStack.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 4, right: 20)
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        footerContainer.backgroundColor = Theme.Color.canvas
        footerContainer.translatesAutoresizingMaskIntoConstraints = false
        let hairline = UIView()
        hairline.backgroundColor = Theme.Color.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addSubview(hairline)
        footerContainer.addSubview(actionStack)

        view.addSubview(scrollView)
        view.addSubview(footerContainer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerContainer.topAnchor),

            footerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            hairline.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),

            actionStack.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            actionStack.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
            actionStack.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
            actionStack.bottomAnchor.constraint(equalTo: footerContainer.safeAreaLayoutGuide.bottomAnchor),
        ])
    }
}
