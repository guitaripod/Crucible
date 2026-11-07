import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Settings › Crucible Server: what it is and how to set it up, or which computer this device is paired with, whether it
/// answers and which model it uses, and the way to unpair.
final class CompanionViewController: UICollectionViewController {
    private enum Row: Hashable {
        case status
        case enterCode
        case howToInstall
        case unpair
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private var status: String = CompanionCopy.checking

    init() {
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = CompanionCopy.title
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "settings.crucibleServer"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = .supplementary
            config.footerMode = .supplementary
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private func refresh() {
        guard let server = CompanionStore.current() else {
            status = CompanionCopy.notSetUp
            applySnapshot()
            return
        }
        status = CompanionCopy.checking
        applySnapshot()
        Task { [weak self] in
            let token = ServerBootstrap.connection()?.authToken ?? ""
            let text: String
            do throws(CompanionError) {
                let brain = try await CompanionClient(server: server, plexToken: token).brain()
                switch (brain.model, brain.reachable) {
                case (let model?, false): text = CompanionCopy.modelSilent(model)
                case (let model, _): text = CompanionCopy.ready(model: model)
                }
            } catch {
                text = error.message
            }
            self?.status = text
            self?.applySnapshot()
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            var content: IconRowContentConfiguration
            switch row {
            case .status:
                content = IconRowContentConfiguration(symbol: "sparkles.tv", title: CompanionStore.current().map { CompanionCopy.paired($0.name) } ?? CompanionCopy.notSetUp, subtitle: status)
            case .enterCode:
                content = IconRowContentConfiguration(symbol: "keyboard", title: CompanionCopy.enterCode)
            case .howToInstall:
                content = IconRowContentConfiguration(symbol: "safari", title: CompanionCopy.howToInstall)
            case .unpair:
                content = IconRowContentConfiguration(symbol: "xmark.circle", title: CompanionCopy.unpair)
            }
            cell.contentConfiguration = content
            cell.accessories = row == .enterCode || row == .howToInstall ? [.disclosureIndicator()] : []
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "settings.crucibleServer.\(row)"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, _ in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = CompanionCopy.pitch
            content.textProperties.font = Theme.Font.subheadline
            content.textProperties.color = Theme.Color.labelSecondary
            content.textProperties.transform = .none
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = CompanionStore.current() == nil ? CompanionCopy.steps : CompanionCopy.addAppleTV
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        let rows: [Row] = CompanionStore.current() == nil ? [.enterCode, .howToInstall] : [.status, .unpair]
        snapshot.appendItems(rows)
        snapshot.reconfigureItems(rows)
        snapshot.reloadSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return false }
        return row != .status
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .enterCode: askForCode()
        case .howToInstall: UIApplication.shared.open(CompanionCopy.installURL)
        case .unpair: confirmUnpair()
        default: break
        }
    }

    private func askForCode() {
        let alert = UIAlertController(title: CompanionCopy.enterCode, message: CompanionCopy.steps, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = CompanionCopy.codePlaceholder
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "settings.crucibleServer.code"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: CompanionCopy.pair, style: .default) { [weak self, weak alert] _ in
            guard let self, let code = alert?.textFields?.first?.text else { return }
            guard let invite = PreviouslyOnRequest.invite(code: code) else {
                CompanionPairingFlow.show(CompanionError.codeRefused.message, from: self)
                return
            }
            CompanionPairingFlow.pair(invite, from: self) { [weak self] in self?.refresh() }
        })
        present(alert, animated: true)
    }

    private func confirmUnpair() {
        let alert = UIAlertController(title: CompanionCopy.unpair, message: CompanionCopy.unpairMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: CompanionCopy.unpair, style: .destructive) { [weak self] _ in
            CompanionStore.forget()
            CompanionAdvertiser.shared.refresh()
            Haptics.success()
            self?.refresh()
        })
        present(alert, animated: true)
    }
}

/// Pairing with Crucible Server from wherever an invite arrives: a scanned code that opened Crucible, or a typed one.
@MainActor
enum CompanionPairingFlow {
    /// Asks before pairing from a link, since a link can come from anywhere.
    static func confirm(_ invite: CompanionInvite, from host: UIViewController, completion: @escaping @MainActor () -> Void = {}) {
        let alert = UIAlertController(title: CompanionCopy.pairQuestion(invite.name), message: CompanionCopy.pitch, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: CompanionCopy.pair, style: .default) { _ in pair(invite, from: host, completion: completion) })
        host.present(alert, animated: true)
    }

    static func pair(_ invite: CompanionInvite, from host: UIViewController, completion: @escaping @MainActor () -> Void) {
        let progress = UIAlertController(title: CompanionCopy.pairing, message: nil, preferredStyle: .alert)
        host.present(progress, animated: true)
        Task { @MainActor in
            let message: String
            do throws(CompanionError) {
                let server = try await PreviouslyOnRequest.pair(invite, deviceName: UIDevice.current.name, platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios")
                Haptics.success()
                message = CompanionCopy.paired(server.name)
            } catch {
                Haptics.error()
                message = error.message
            }
            CompanionAdvertiser.shared.refresh()
            progress.dismiss(animated: true) {
                show(message, from: host)
                completion()
            }
        }
    }

    /// Hands the server the secret an Apple TV shows as a QR code, after asking, so that Apple TV can finish pairing.
    static func confirmAdd(_ device: CompanionDeviceInvite, from host: UIViewController) {
        guard let client = PreviouslyOnRequest.client() else {
            show(CompanionCopy.pairThisIPhoneFirst, from: host)
            return
        }
        guard !device.isExpired() else {
            show(CompanionCopy.tvCodeExpired, from: host)
            return
        }
        let alert = UIAlertController(title: CompanionCopy.addQuestion(device: device.name, server: client.server.name), message: CompanionCopy.addWarning, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: CompanionCopy.allow, style: .default) { _ in
            guard !device.isExpired() else {
                show(CompanionCopy.tvCodeExpired, from: host)
                return
            }
            Task { @MainActor in
                do throws(CompanionError) {
                    try await client.addDevice(secret: device.secret)
                    Haptics.success()
                    show(CompanionCopy.added(device.name), from: host)
                } catch {
                    Haptics.error()
                    show(error.message, from: host)
                }
            }
        })
        host.present(alert, animated: true)
    }

    static func show(_ message: String, from host: UIViewController) {
        let alert = UIAlertController(title: CompanionCopy.title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        host.present(alert, animated: true)
    }
}
