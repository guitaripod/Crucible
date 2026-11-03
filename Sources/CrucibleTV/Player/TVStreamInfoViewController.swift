import CrucibleCore
import CrucibleDesign
import UIKit

/// The Stream Info panel in the player's info area: how the title reaches the screen, one label and value per line.
final class TVStreamInfoViewController: UIViewController {
    private let stack = UIStackView()

    init(lines: [StreamInfoLine]) {
        super.init(nibName: nil, bundle: nil)
        title = StreamInfo.title
        stack.axis = .vertical
        stack.spacing = 14
        for line in lines {
            stack.addArrangedSubview(Self.row(line))
        }
        preferredContentSize = CGSize(width: 1_400, height: CGFloat(lines.count) * 50 + 80)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -60),
        ])
        view.accessibilityIdentifier = "player.streamInfo"
    }

    private static func row(_ line: StreamInfoLine) -> UIView {
        let label = UILabel()
        label.font = Theme.Font.callout
        label.textColor = Theme.Color.labelSecondary
        label.text = line.label
        label.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let value = UILabel()
        value.font = Theme.Font.callout
        value.textColor = Theme.Color.label
        value.text = line.value
        value.numberOfLines = 2
        let row = UIStackView(arrangedSubviews: [label, value])
        row.axis = .horizontal
        row.spacing = 24
        row.alignment = .firstBaseline
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(line.label), \(line.value)"
        return row
    }
}
