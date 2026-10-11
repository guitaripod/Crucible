import CrucibleCore
import CrucibleDesign
import UIKit

/// Lists the account's Plex servers with the route Crucible found fastest, and connects. With a
/// single server it connects by itself; with several, once exactly one answers it continues
/// automatically. A server that does not answer can be tested again, and an address can always be
/// typed instead.
final class TVChooseServerViewController: TVOnboardingViewController, UICollectionViewDelegate {
    private enum RowKind {
        case server(String)
        case addAddress
        case retry
        case signInAgain
    }

    private static let columnWidth: CGFloat = 1100
    private static let addAddressID = "action.addAddress"
    private static let retryID = "action.retry"
    private static let signInAgainID = "action.signInAgain"

    private let token: String
    private let discovery: ServerDiscovery
    private var picker: ServerPickerState?
    private var rows: [String] = []
    private var singleServer: ServerChoice?
    private var isConnecting = false
    private var userMovedFocus = false
    private var allowsAutoContinue = false
    private var loadTask: Task<Void, Never>?
    private var probeTasks: [Task<Void, Never>] = []
    private var connectTask: Task<Void, Never>?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let errorLabel = UILabel()
    private let headerStack = UIStackView()
    private let stateView = TVStateView()
    private let focusMemory = TVFocusMemory()
    private var collectionView: TVCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(flow: TVOnboardingFlow, token: String) {
        self.token = token
        self.discovery = ServerDiscovery(token: token)
        super.init(flow: flow)
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        isConnecting || rows.isEmpty ? [stateView] : [collectionView]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeader()
        installCollectionView()
        installStateView()
        configureDataSource()
        load()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || isBeingDismissed || navigationController == nil else { return }
        loadTask?.cancel()
        cancelProbes()
        connectTask?.cancel()
    }

    private func load() {
        loadTask?.cancel()
        cancelProbes()
        picker = nil
        singleServer = nil
        setBusy("Finding your servers…")
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch try await discovery.listing() {
                case .none:
                    show(
                        title: "No Plex Server Found",
                        subtitle: "This account doesn't own or share a Plex Media Server. Sign in with the account that has your server, or add one by its address.",
                        rows: [Self.addAddressID, Self.retryID]
                    )
                case .single(let server):
                    singleServer = server
                    await connectToOnly(server)
                case .several(let servers):
                    showServers(servers)
                }
            } catch {
                guard !Task.isCancelled else { return }
                showLoadFailure(error)
            }
        }
    }

    private func showLoadFailure(_ error: Error) {
        if let apiError = error as? APIError, case .unauthorized = apiError {
            show(
                title: "Sign-in Expired",
                subtitle: "Plex needs you to sign in again before Crucible can list your servers.",
                rows: [Self.signInAgainID, Self.addAddressID]
            )
        } else {
            show(
                title: "Couldn't Load Your Servers",
                subtitle: ConnectionError.message(for: error),
                rows: [Self.retryID, Self.addAddressID]
            )
        }
    }

    private func connectToOnly(_ server: ServerChoice) async {
        let outcome = await discovery.connect(toOnly: server) { [weak self] progress in
            self?.setBusy(progress.message)
        }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .connected(let connection):
            flow.didConnect(connection)
        case .needsAddress(let message):
            show(
                title: "Couldn't Reach \(server.name)",
                subtitle: message ?? "Crucible found no route to this server. Enter its address instead.",
                rows: [Self.addAddressID, Self.retryID]
            )
        case .failed(let message):
            show(title: "Couldn't Connect to \(server.name)", subtitle: message, rows: [Self.retryID, Self.addAddressID])
        case .cancelled:
            break
        }
    }

    private func showServers(_ servers: [ServerChoice]) {
        var state = ServerPickerState(choices: servers)
        for (server, route) in state.unprobeableRoutes {
            state.record(server: server, route: route, milliseconds: nil)
        }
        picker = state
        userMovedFocus = false
        allowsAutoContinue = true
        show(
            title: "Choose Server",
            subtitle: "Crucible tests every connection and picks the fastest.",
            rows: servers.map { Self.rowID(forServer: $0.id) } + [Self.addAddressID]
        )
        startProbing(state.probeTargets)
    }

    private func startProbing(_ targets: [RouteProbeTarget]) {
        let measurements = discovery.measureRoutes(targets)
        probeTasks.append(Task { [weak self] in
            for await measurement in measurements {
                guard !Task.isCancelled else { return }
                self?.record(measurement)
            }
            guard !Task.isCancelled else { return }
            self?.probingFinished()
        })
    }

    private func cancelProbes() {
        probeTasks.forEach { $0.cancel() }
        probeTasks = []
    }

    private func record(_ measurement: RouteMeasurement) {
        guard picker?.record(server: measurement.serverID, route: measurement.routeIndex, milliseconds: measurement.milliseconds) == true else { return }
        reconfigure([Self.rowID(forServer: measurement.serverID)])
        continueAutomaticallyIfDecided()
    }

    /// Continues by itself when exactly one server answered, as soon as every server's best route
    /// is known and without waiting for slower routes to time out.
    private func continueAutomaticallyIfDecided() {
        guard allowsAutoContinue, !isConnecting, let target = picker?.autoContinue else { return }
        allowsAutoContinue = false
        connect(target.choice, route: target.route)
    }

    /// Prefers the fastest server once every probe has settled, unless the person already moved.
    private func probingFinished() {
        guard var state = picker else { return }
        let selectionMoved = state.finishProbing()
        picker = state
        if selectionMoved, !userMovedFocus, !isConnecting {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    private func connect(_ choice: ServerChoice, route: ServerRoute) {
        guard !isConnecting else { return }
        errorLabel.isHidden = true
        setBusy("Connecting to \(choice.name)…")
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await discovery.connect(to: choice, route: route) { [weak self] progress in
                self?.setBusy(progress.message)
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .connected(let connection):
                flow.didConnect(connection)
            case .failed(let message):
                endBusy()
                showError(message)
            case .needsAddress(let message):
                endBusy()
                flow.addByAddress(token: token, known: choice, message: message, from: self)
            case .cancelled:
                endBusy()
            }
        }
    }

    private func retest(_ id: String) {
        guard var state = picker else { return }
        let targets = state.restartProbing(of: id)
        picker = state
        guard !targets.isEmpty else { return }
        allowsAutoContinue = false
        reconfigure([Self.rowID(forServer: id)])
        startProbing(targets)
    }

    private func show(title: String, subtitle: String, rows newRows: [String]) {
        isConnecting = false
        rows = newRows
        errorLabel.isHidden = true
        titleLabel.text = title
        subtitleLabel.text = subtitle
        stateView.isHidden = true
        collectionView.isHidden = false
        headerStack.isHidden = false
        applyRows(reload: true)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    private func setBusy(_ status: String) {
        isConnecting = true
        stateView.show(.loading(title: status))
        stateView.isHidden = false
        collectionView.isHidden = true
        headerStack.isHidden = true
    }

    private func endBusy() {
        isConnecting = false
        stateView.isHidden = true
        collectionView.isHidden = false
        headerStack.isHidden = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func showError(_ text: String) {
        errorLabel.text = text
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func installHeader() {
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityTraits = .header
        subtitleLabel.font = Theme.Font.callout
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 3
        errorLabel.font = Theme.Font.callout
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 3
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "onboarding.error"

        let header = headerStack
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(subtitleLabel)
        header.addArrangedSubview(errorLabel)
        header.axis = .vertical
        header.alignment = .fill
        header.spacing = Theme.Space.s
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.Space.l),
            header.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            header.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
    }

    private func installCollectionView() {
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: TVRowList.layout())
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "onboarding.servers"
        view.addSubview(collectionView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: Theme.Space.m),
            collectionView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            collectionView.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
    }

    private func installStateView() {
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private static func rowID(forServer id: String) -> String { "server.\(id)" }

    private func kind(of id: String) -> RowKind? {
        switch id {
        case Self.addAddressID: return .addAddress
        case Self.retryID: return .retry
        case Self.signInAgainID: return .signInAgain
        default:
            guard id.hasPrefix("server.") else { return nil }
            return .server(String(id.dropFirst("server.".count)))
        }
    }

    private func rowItem(for id: String) -> TVRowItem {
        switch kind(of: id) {
        case .server(let serverID):
            guard let choice = picker?.choice(withID: serverID) else { return TVRowItem(id: id, title: "Server") }
            return TVRowItem(
                id: id,
                title: choice.name,
                subtitle: choice.statusLine,
                value: choice.routeValue,
                symbol: Self.symbol(for: choice),
                accessory: .chevron,
                isEnabled: choice.reachability != .offline
            )
        case .addAddress:
            return TVRowItem(id: id, title: "Add by Address", subtitle: "Type an IP address or hostname", symbol: "plus", accessory: .chevron)
        case .retry:
            return TVRowItem(id: id, title: "Try Again", symbol: "arrow.clockwise")
        case .signInAgain:
            return TVRowItem(id: id, title: "Sign In Again", symbol: "person.crop.circle.badge.checkmark", accessory: .chevron)
        case nil:
            return TVRowItem(id: id, title: "")
        }
    }

    private static func symbol(for choice: ServerChoice) -> String {
        switch choice.reachability {
        case .offline: return "moon.zzz"
        case .unreachable: return "exclamationmark.triangle"
        case .probing: return "server.rack"
        case .reachable:
            switch choice.bestRoute?.kind {
            case .local: return "wifi"
            case .tailscale: return "network"
            case .relay: return "arrow.triangle.swap"
            case .remote, nil: return "globe"
            }
        }
    }

    private func configureDataSource() {
        let registration = TVRowCell.registration()
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let item = self?.rowItem(for: id) ?? TVRowItem(id: id, title: "")
            return collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
    }

    private func applyRows(reload: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows, toSection: 0)
        if reload { snapshot.reloadItems(rows) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigure(_ ids: [String]) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(ids.filter { snapshot.itemIdentifiers.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath), case .server(let serverID)? = kind(of: id) else { return true }
        return picker?.isSelectable(serverID) ?? false
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let remembered = focusMemory.preferredIndexPath(in: collectionView), userMovedFocus { return remembered }
        let preferred = picker?.selectedID.map { Self.rowID(forServer: $0) } ?? rows.first
        return preferred.flatMap { dataSource.indexPath(for: $0) }
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        if context.previouslyFocusedIndexPath != nil { userMovedFocus = true }
        focusMemory.record(context)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isConnecting, let id = dataSource.itemIdentifier(for: indexPath), let kind = kind(of: id) else { return }
        switch kind {
        case .server(let serverID):
            select(serverID)
        case .addAddress:
            flow.addByAddress(token: token, known: singleServer, message: nil, from: self)
        case .retry:
            load()
        case .signInAgain:
            flow.signInAgain(from: self)
        }
    }

    private func select(_ serverID: String) {
        guard let choice = picker?.choice(withID: serverID) else { return }
        guard let route = choice.bestRoute else {
            if choice.reachability == .unreachable { retest(serverID) }
            return
        }
        connect(choice, route: route)
    }
}
