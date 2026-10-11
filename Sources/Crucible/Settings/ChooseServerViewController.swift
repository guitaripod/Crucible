import CrucibleCore
import CrucibleDesign
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

    private let discovery: ServerDiscovery
    private var picker: ServerPickerState
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
        self.picker = ServerPickerState(choices: choices)
        self.discovery = ServerDiscovery(token: token)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
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
            guard let self, let choice = picker.choice(withID: id) else { return }
            cell.contentConfiguration = ChooseServerCardConfiguration(choice: choice, isSelected: id == picker.selectedID)
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
        snapshot.appendItems(picker.choices.map { .server($0.id) } + [.addByAddress, .hint], toSection: 0)
        snapshot.reconfigureItems(reconfigure.map { .server($0) })
        dataSource.apply(snapshot, animatingDifferences: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard !isConnecting, let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .server(let id): return picker.isSelectable(id)
        case .addByAddress: return true
        case .hint: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .server(let id):
            let previous = picker.selectedID
            guard picker.choose(id) else { return }
            Haptics.selection()
            selectionChanged(from: previous)
        case .addByAddress:
            onAddByAddress?()
        case .hint:
            break
        }
    }

    private func selectionChanged(from previous: String?) {
        errorLabel.isHidden = true
        applySnapshot(animated: true, reconfigure: [previous, picker.selectedID].compactMap { $0 })
        updateConnectButton()
    }

    private func startProbing() {
        for (server, route) in picker.unprobeableRoutes {
            record(server: server, route: route, milliseconds: nil)
        }

        let measurements = discovery.measureRoutes(picker.probeTargets)
        probeTask = Task { [weak self] in
            for await measurement in measurements {
                guard !Task.isCancelled else { return }
                self?.record(server: measurement.serverID, route: measurement.routeIndex, milliseconds: measurement.milliseconds)
            }
            guard !Task.isCancelled else { return }
            self?.probingFinished()
        }
    }

    private func record(server: String, route: Int, milliseconds: Int?) {
        guard picker.record(server: server, route: route, milliseconds: milliseconds) else { return }
        applySnapshot(animated: true, reconfigure: [server])
        updateConnectButton()
    }

    /// Preselects the lowest-latency server once every probe has settled, unless the user already chose.
    private func probingFinished() {
        let previous = picker.selectedID
        if picker.finishProbing() {
            selectionChanged(from: previous)
        }
    }

    private func connectTapped() {
        guard !isConnecting, let choice = picker.selectedChoice, let route = choice.bestRoute else { return }
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
        let action = picker.connectAction(isConnecting: isConnecting)
        var config = ThemeButton.primaryConfiguration(title: action.title)
        config.showsActivityIndicator = action.showsActivity
        connectButton.configuration = config
        connectButton.isEnabled = action.isEnabled
    }
}
