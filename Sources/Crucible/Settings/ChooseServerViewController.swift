@preconcurrency import UIKit

/// The "Choose Server" step shown after sign-in when the account owns or shares more than one
/// server. Every route of every online server is probed in parallel; the fastest server is
/// preselected and the selected card expands to show what was measured.
final class ChooseServerViewController: UIViewController, UICollectionViewDelegate {
    private enum Item: Hashable {
        case server(String)
        case addByAddress
        case hint
    }

    var onBack: (() -> Void)?
    var onAddByAddress: (() -> Void)?
    var onConnect: ((ServerChoice, ServerRoute) async -> String?)?

    private let token: String
    private var choices: [ServerChoice]
    private var selectedID: String?
    private var userChoseServer = false
    private var isConnecting = false

    private let backButton = ThemeButton.icon(symbol: "chevron.left", label: "Back")
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let errorLabel = UILabel()
    private let connectButton = ThemeButton.primary(title: "Connect")
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var probeTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    init(choices: [ServerChoice], token: String) {
        self.choices = choices
        self.token = token
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        selectedID = choices.first(where: \.isOnline)?.id
        configureHeader()
        configureCollectionView()
        configureFooter()
        applySnapshot(animated: false)
        updateConnectButton()
        startProbing()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            probeTask?.cancel()
            connectTask?.cancel()
        }
    }

    private func configureHeader() {
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)

        titleLabel.text = "Choose Server"
        titleLabel.font = Theme.Font.largeTitle
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        subtitleLabel.text = "Crucible tested every connection and picked the fastest."
        subtitleLabel.font = Theme.Font.subheadline
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.numberOfLines = 0

        let backRow = UIStackView(arrangedSubviews: [backButton, UIView()])
        backRow.axis = .horizontal

        let header = UIStackView(arrangedSubviews: [backRow, titleLabel, subtitleLabel])
        header.axis = .vertical
        header.spacing = 6
        header.setCustomSpacing(2, after: backRow)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        headerBottomAnchor = header.bottomAnchor
    }

    private var headerBottomAnchor: NSLayoutYAxisAnchor!

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 12
            section.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 16, bottom: 120, trailing: 16)
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(collectionView, at: 0)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerBottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let serverReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let choice = choices.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = ServerCardContentConfiguration(choice: choice, isSelected: id == selectedID)
            cell.backgroundConfiguration = .clear()
        }

        let addReg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Add by address…"
            content.image = UIImage(systemName: "plus")
            content.textProperties.font = Theme.Font.scaled(.callout, 16, .semibold)
            content.textProperties.color = Theme.Color.accentText
            content.imageProperties.tintColor = Theme.Color.accentText
            content.imageToTextPadding = 12
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16)
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
            cell.accessibilityTraits = .button
        }

        let hintReg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "A hostname or IP such as 100.x.x.x for Tailscale. Crucible tries HTTPS first."
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
        }

        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .server(let id): return collectionView.dequeueConfiguredReusableCell(using: serverReg, for: indexPath, item: id)
            case .addByAddress: return collectionView.dequeueConfiguredReusableCell(using: addReg, for: indexPath, item: 0)
            case .hint: return collectionView.dequeueConfiguredReusableCell(using: hintReg, for: indexPath, item: 0)
            }
        }
    }

    private func configureFooter() {
        errorLabel.font = Theme.Font.footnote
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        connectButton.addAction(UIAction { [weak self] _ in self?.connectTapped() }, for: .touchUpInside)
        connectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        let stack = UIStackView(arrangedSubviews: [errorLabel, connectButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -22),
        ])
    }

    private func applySnapshot(animated: Bool, reconfigure: [String] = []) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(choices.map { .server($0.id) } + [.addByAddress, .hint], toSection: 0)
        snapshot.reconfigureItems(reconfigure.map { .server($0) })
        dataSource.apply(snapshot, animatingDifferences: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard !isConnecting, let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .server(let id): return choices.first(where: { $0.id == id })?.isOnline == true
        case .addByAddress: return true
        case .hint: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .server(let id):
            guard id != selectedID else { return }
            Haptics.selection()
            userChoseServer = true
            select(id)
        case .addByAddress:
            onAddByAddress?()
        case .hint:
            break
        }
    }

    private func select(_ id: String) {
        let previous = selectedID
        selectedID = id
        errorLabel.isHidden = true
        applySnapshot(animated: true, reconfigure: [previous, id].compactMap { $0 })
        updateConnectButton()
    }

    private var selectedChoice: ServerChoice? {
        choices.first { $0.id == selectedID }
    }

    private func startProbing() {
        let token = token
        let targets: [(server: String, index: Int, url: URL)] = choices.filter(\.isOnline).flatMap { choice in
            choice.routes.enumerated().compactMap { index, route in
                URL(string: route.uri).map { (choice.id, index, $0) }
            }
        }
        for choice in choices where choice.isOnline {
            for (index, route) in choice.routes.enumerated() where URL(string: route.uri) == nil {
                record(server: choice.id, route: index, milliseconds: nil)
            }
        }

        probeTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int, Int?).self) { group in
                for target in targets {
                    group.addTask { (target.server, target.index, await ServerRouteProbe.measure(target.url, token: token)) }
                }
                for await (server, index, milliseconds) in group {
                    guard !Task.isCancelled else { return }
                    self?.record(server: server, route: index, milliseconds: milliseconds)
                }
            }
            guard !Task.isCancelled else { return }
            self?.probingFinished()
        }
    }

    private func record(server: String, route: Int, milliseconds: Int?) {
        guard let position = choices.firstIndex(where: { $0.id == server }) else { return }
        choices[position].record(routeAt: route, milliseconds: milliseconds)
        applySnapshot(animated: true, reconfigure: [server])
        updateConnectButton()
    }

    /// Preselects the lowest-latency server once every probe has settled, unless the user already chose.
    private func probingFinished() {
        guard !userChoseServer else { return }
        let fastest = choices
            .filter(\.isOnline)
            .compactMap { choice in choice.fastestMilliseconds.map { (choice.id, $0) } }
            .min { $0.1 < $1.1 }
        if let fastest, fastest.0 != selectedID {
            select(fastest.0)
        }
    }

    private func connectTapped() {
        guard !isConnecting, let choice = selectedChoice, let route = choice.bestRoute else { return }
        isConnecting = true
        errorLabel.isHidden = true
        updateConnectButton()
        connectTask = Task { [weak self] in
            guard let self else { return }
            let failure = await onConnect?(choice, route)
            guard !Task.isCancelled else { return }
            isConnecting = false
            if let failure {
                Haptics.error()
                errorLabel.text = failure
                errorLabel.isHidden = false
                UIAccessibility.post(notification: .announcement, argument: failure)
            }
            updateConnectButton()
        }
    }

    private func updateConnectButton() {
        var config = ThemeButton.primaryConfiguration(title: "Connect")
        var enabled = false
        if isConnecting {
            config.title = "Connecting…"
            config.showsActivityIndicator = true
        } else if let choice = selectedChoice {
            if choice.bestRoute != nil {
                config.title = "Connect to \(choice.name)"
                enabled = true
            } else if choice.isProbing {
                config.title = "Testing connections…"
                config.showsActivityIndicator = true
            } else {
                config.title = "No route to \(choice.name)"
            }
        } else {
            config.title = "Choose a Server"
        }
        connectButton.configuration = config
        connectButton.isEnabled = enabled
    }
}
