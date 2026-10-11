import CrucibleCore
import CrucibleDesign
import UIKit

/// Server & Connection: the server card on the left, every known route with its measured latency,
/// the connection preferences and the ways to add or change server on the right.
final class TVServerSettingsViewController: TVSettingsScaffold {
    private enum RowID {
        static let test = "server.test"
        static let preferLocal = "server.preferLocal"
        static let allowRelay = "server.allowRelay"
        static let addServer = "server.addServer"
        static let switchServer = "server.switchServer"
        static let routePrefix = "server.route."
    }

    private let env: TVAppEnvironment
    private let model = ServerConnectionModel()
    private let card = TVServerCardView()

    init(env: TVAppEnvironment) {
        self.env = env
        super.init()
        title = "Server & Connection"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContext(card)
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        render()
        model.startIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            model.stop()
        }
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case RowID.test:
            if !model.isTesting { model.runTest() }
        case RowID.preferLocal:
            flip(.preferLocalConnection)
        case RowID.allowRelay:
            flip(.allowRelayConnection)
        case RowID.addServer:
            TVNavigation.push(TVAddServerViewController(env: env), from: self)
        case RowID.switchServer:
            env.session.switchServer()
        default:
            break
        }
    }

    private func flip(_ setting: PreferenceSetting) {
        setting.setOn(!setting.isOn)
        render()
    }

    private func render() {
        card.configure(model.card)
        var rows = model.routeRows.map(routeRow)
        rows.append(TVRowItem(
            id: RowID.test,
            title: "Test Connection",
            value: model.isTesting ? "Testing…" : nil,
            symbol: "bolt.horizontal"
        ))
        rows.append(toggleRow(RowID.preferLocal, .preferLocalConnection, symbol: "wifi"))
        rows.append(toggleRow(RowID.allowRelay, .allowRelayConnection, symbol: "arrow.triangle.swap"))
        rows.append(TVRowItem(id: RowID.addServer, title: "Add Server by Address", symbol: "plus", accessory: .chevron))
        rows.append(TVRowItem(id: RowID.switchServer, title: "Switch Server", symbol: "arrow.left.arrow.right", accessory: .chevron))
        setRows(rows)
    }

    private func routeRow(_ route: ServerConnectionModel.RouteRow) -> TVRowItem {
        TVRowItem(
            id: RowID.routePrefix + route.url.absoluteString,
            title: route.kindTitle,
            subtitle: route.isInUse ? "In use · \(route.detail)" : route.detail,
            value: route.latencyText,
            symbol: route.kind.symbolName,
            accessory: route.isInUse ? .checkmark : .none,
            isEnabled: !route.isDimmed
        )
    }

    private func toggleRow(_ id: String, _ setting: PreferenceSetting, symbol: String) -> TVRowItem {
        TVRowItem(id: id, title: setting.title, value: setting.valueLabel, symbol: symbol)
    }
}

/// The active server: its name, the Plex Media Server version and ownership, and a status line
/// with a dot coloured by the health of the active route.
final class TVServerCardView: TVReadOnlyPanel {
    private let iconWell = UIImageView(image: UIImage(systemName: "server.rack"))
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusDot = TVStatusDot(color: Theme.Color.labelTertiary)
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: ServerConnectionModel.Card) {
        nameLabel.text = card.name
        subtitleLabel.text = card.subtitle
        statusLabel.text = card.status
        statusDot.setColor(card.tone.color)
        accessibilityLabel = "\(card.name), \(card.subtitle), \(card.status)"
    }

    private func build() {
        iconWell.contentMode = .center
        iconWell.tintColor = Theme.Color.accentText
        iconWell.backgroundColor = Theme.Color.accentTint
        iconWell.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
        iconWell.layer.cornerRadius = Theme.Radius.l
        iconWell.layer.cornerCurve = .continuous
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconWell.widthAnchor.constraint(equalToConstant: 140),
            iconWell.heightAnchor.constraint(equalToConstant: 140),
        ])

        nameLabel.font = Theme.Font.title2
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 2
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.6
        subtitleLabel.font = Theme.Font.callout
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.numberOfLines = 2

        statusLabel.font = Theme.Font.callout
        statusLabel.textColor = Theme.Color.label
        statusLabel.numberOfLines = 0
        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusLabel])
        statusRow.spacing = Theme.Space.xs
        statusRow.alignment = .center

        let text = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel, statusRow])
        text.axis = .vertical
        text.spacing = Theme.Space.xs
        text.setCustomSpacing(Theme.Space.s, after: subtitleLabel)

        let root = UIStackView(arrangedSubviews: [iconWell, text])
        root.axis = .vertical
        root.spacing = Theme.Space.m
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        accessibilityIdentifier = "server.card"
    }
}
