import CrucibleDesign
import UIKit

/// The chassis of the demo's two full-screen messages, the welcome and the finale: the onboarding backdrop and two columns centred on
/// the screen, text on the left and what the person can do on the right. Subclasses supply the columns and the control that takes
/// focus; Menu closes the screen like its quietest button does.
class TVDemoModalViewController: UIViewController {
    private enum Layout {
        static let textWidth: CGFloat = 780
        static let columnGap: CGFloat = 96
    }

    private lazy var leadingColumn = makeLeadingColumn()
    private lazy var trailingColumn = makeTrailingColumn()

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var focusTarget: UIView? { nil }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        focusTarget.map { [$0] } ?? []
    }

    func makeLeadingColumn() -> UIView { UIView() }

    func makeTrailingColumn() -> UIView { UIView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        view.accessibilityViewIsModal = true
        installBackdrop()
        installColumns()
    }

    /// A large title that VoiceOver reads as a header.
    static func makeTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.largeTitle
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        return label
    }

    static func makeBody(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.body
        label.textColor = Theme.Color.labelSecondary
        label.numberOfLines = 0
        return label
    }

    private func installBackdrop() {
        let backdrop = TVOnboardingBackdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func installColumns() {
        let columns = UIStackView(arrangedSubviews: [leadingColumn, trailingColumn])
        columns.axis = .horizontal
        columns.alignment = .center
        columns.distribution = .fillEqually
        columns.spacing = Layout.columnGap
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            columns.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            columns.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            columns.widthAnchor.constraint(equalToConstant: Layout.textWidth * 2 + Layout.columnGap),
            columns.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
        ])
    }
}
