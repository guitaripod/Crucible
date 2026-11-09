import CrucibleCore
import CrucibleDesign
import SafariServices
@preconcurrency import UIKit

/// Settings › Integrations › Seerr › Set Up Seerr: the steps from no Seerr to requesting from anywhere, written for the system
/// the Plex server runs on, with commands to copy and links to open. Crucible checks each step while the screen is open
/// (Seerr answering next to the server, its setup finished, Tailscale on this device and the server) and offers Connect the
/// moment Seerr is ready.
final class SeerrGuideViewController: UICollectionViewController {
    private enum Section: Hashable {
        case intro
        case step(SeerrGuide.Step)
        case trouble
        case connect
    }

    private enum Row: Hashable {
        case intro
        case host
        case notOwner
        case share
        case enterAddress
        case status(String, StatusKind)
        case line(SeerrGuideLine)
        case connect
    }

    enum StatusKind: Hashable {
        case busy
        case done
        case waiting
        case problem
    }

    private let watcher: SeerrSetupWatcher
    private let onReady: (URL, SeerrPublicSettings) -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var copiedCommand: String?
    private var wasReady = false

    init(api: APIClient, onReady: @escaping (URL, SeerrPublicSettings) -> Void) {
        watcher = SeerrSetupWatcher(api: api)
        self.onReady = onReady
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SeerrGuide.title
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "seerrGuide"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.headerMode = .supplementary
            config.itemSeparatorHandler = { _, separator in
                var separator = separator
                separator.topSeparatorVisibility = .hidden
                separator.bottomSeparatorVisibility = .hidden
                return separator
            }
            if self?.dataSource?.sectionIdentifier(for: index) == .intro { config.headerMode = .none }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        watcher.start { [weak self] in self?.watcherChanged() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        watcher.stop()
    }

    /// Seerr becoming ready brings Connect into view, once, wherever the viewer had scrolled to.
    private func watcherChanged() {
        applySnapshot()
        let ready = watcher.seerr.isReady
        defer { wasReady = ready }
        guard ready, !wasReady, let path = dataSource.indexPath(for: .connect) else { return }
        Haptics.success()
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: 0, section: path.section), at: .top, animated: !UIAccessibility.isReduceMotionEnabled)
        UIAccessibility.post(notification: .announcement, argument: SeerrGuide.readyToConnect)
    }

    private var deviceName: String {
        traitCollection.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.intro])
        var intro: [Row] = [.intro, .host]
        if !ServerOwnership.isOwner() { intro.append(.notOwner) }
        intro.append(.share)
        snapshot.appendItems(intro, toSection: .intro)
        if watcher.seerr.isReady {
            snapshot.appendSections([.connect])
            snapshot.appendItems([.status(SeerrGuide.readyToConnect, .done), .connect], toSection: .connect)
        }
        for step in SeerrGuide.Step.allCases {
            snapshot.appendSections([.step(step)])
            let lines = SeerrGuide.lines(step, host: watcher.host, home: watcher.homeHost, server: watcher.serverName, platformName: deviceName)
            snapshot.appendItems(statuses(for: step) + lines.map(Row.line), toSection: .step(step))
        }
        snapshot.appendSections([.trouble])
        snapshot.appendItems(SeerrGuide.trouble(home: watcher.homeHost).map(Row.line) + [.enterAddress], toSection: .trouble)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func statuses(for step: SeerrGuide.Step) -> [Row] {
        let home = "\(watcher.homeHost ?? SeerrGuide.placeholderAddress):\(SeerrDiscovery.defaultPort)"
        switch step {
        case .install:
            switch watcher.seerr {
            case .looking: return [.status(SeerrGuide.looking, .busy)]
            case .notFound: return [.status(SeerrGuide.notYet(home), .waiting)]
            case .needsSetup(let url), .notPlex(let url), .ready(let url, _): return [.status(SeerrGuide.running(SeerrDiscovery.displayAddress(url)), .done)]
            }
        case .setUp:
            switch watcher.seerr {
            case .ready: return [.status(SeerrGuide.setUpDone, .done)]
            case .needsSetup: return [.status(SeerrGuide.needsSetup, .waiting)]
            case .notPlex: return [.status(SeerrGuide.notPlex, .problem)]
            case .looking, .notFound: return []
            }
        case .away:
            let device = watcher.deviceOnTailnet ? Row.status(SeerrGuide.deviceOnTailnet(deviceName), .done) : Row.status(SeerrGuide.deviceOffTailnet(deviceName), .waiting)
            let server = watcher.tailnetHost.map { Row.status(SeerrGuide.serverOnTailnet($0), .done) } ?? Row.status(SeerrGuide.serverOffTailnet, .waiting)
            return [device, server]
        case .downloads, .people:
            return []
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let self, let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            switch section {
            case .step(let step):
                content.text = "\(step.rawValue + 1). \(SeerrGuide.title(step))"
                if step == .downloads { content.secondaryText = SeerrGuide.optional }
            case .trouble: content.text = SeerrGuide.troubleTitle
            case .connect: content.text = SeerrCopy.found
            case .intro: content.text = nil
            }
            content.textProperties.color = Theme.Color.label
            cell.contentConfiguration = content
            cell.accessibilityTraits = .header
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, row: Row) {
        cell.accessories = []
        cell.applyThemedBackground()
        cell.accessibilityTraits = []
        cell.accessibilityIdentifier = nil
        switch row {
        case .intro:
            cell.contentConfiguration = Self.paragraph(SeerrGuide.intro)
        case .host:
            var content = IconRowContentConfiguration(symbol: "server.rack", title: SeerrGuide.hostQuestion, value: watcher.host.title)
            content.menu = hostMenu()
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "seerrGuide.host"
        case .notOwner:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "person.2", title: SeerrGuide.notOwner)
        case .share:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "square.and.arrow.up", title: SeerrGuide.openOnComputer, isActionable: true)
            cell.accessibilityIdentifier = "seerrGuide.share"
        case .enterAddress:
            cell.contentConfiguration = IconRowContentConfiguration(symbol: "keyboard", title: SeerrCopy.enterAddress, isActionable: true)
            cell.accessibilityIdentifier = "seerrGuide.enterAddress"
        case .status(let text, let kind):
            cell.contentConfiguration = IconRowContentConfiguration(symbol: Self.symbol(kind), symbolColor: Self.color(kind), title: text)
            if kind == .busy { cell.accessories = [.customView(configuration: .init(customView: Self.spinner(), placement: .trailing()))] }
            cell.accessibilityIdentifier = "seerrGuide.status"
        case .line(let line):
            switch line {
            case .text(let text):
                cell.contentConfiguration = Self.paragraph(text)
            case .command(let command):
                cell.contentConfiguration = GuideCommandConfiguration(command: command, copied: copiedCommand == command) { [weak self] in
                    self?.copy(command)
                }
            case .link(let title, _):
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "arrow.up.forward.square", title: title, isActionable: true)
            }
        case .connect:
            var content = UIListContentConfiguration.cell()
            content.text = SeerrCopy.connect
            content.textProperties.font = Theme.Font.headline
            content.textProperties.color = Theme.Color.accentText
            content.textProperties.alignment = .center
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16)
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "seerrGuide.connect"
        }
    }

    private static func paragraph(_ text: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = text
        content.textProperties.font = Theme.Font.subheadline
        content.textProperties.color = Theme.Color.label
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        return content
    }

    private static func color(_ kind: StatusKind) -> UIColor {
        switch kind {
        case .done: return Theme.Color.statusOK
        case .problem: return Theme.Color.destructive
        case .busy, .waiting: return Theme.Color.labelSecondary
        }
    }

    private static func symbol(_ kind: StatusKind) -> String {
        switch kind {
        case .busy: return "dot.radiowaves.left.and.right"
        case .done: return "checkmark.circle.fill"
        case .waiting: return "circle.dashed"
        case .problem: return "exclamationmark.triangle"
        }
    }

    private static func spinner() -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return spinner
    }

    private func hostMenu() -> UIMenu {
        let actions = SeerrHost.allCases.map { host in
            UIAction(title: host.title, state: host == watcher.host ? .on : .off) { [weak self] _ in
                self?.watcher.choose(host)
            }
        }
        return UIMenu(title: SeerrGuide.hostQuestion, options: .singleSelection, children: actions)
    }

    private func copy(_ command: String) {
        UIPasteboard.general.string = command
        Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: SeerrGuide.copied)
        copiedCommand = command
        applySnapshot()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, copiedCommand == command else { return }
            copiedCommand = nil
            applySnapshot()
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .share, .connect, .enterAddress: return true
        case .line(.link): return true
        default: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .share:
            share(from: collectionView.cellForItem(at: indexPath))
        case .enterAddress:
            askForAddress()
        case .connect:
            guard case .ready(let url, let settings) = watcher.seerr else { return }
            onReady(url, settings)
        case .line(.link(_, let url)):
            present(SFSafariViewController(url: url), animated: true)
        default:
            break
        }
    }

    private func askForAddress() {
        let alert = UIAlertController(title: SeerrCopy.addressTitle, message: SeerrCopy.addressMessage, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = SeerrCopy.addressPlaceholder
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.textContentType = .URL
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SeerrGuide.lookThere, style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            self?.watcher.add(typed: text)
        })
        present(alert, animated: true)
    }

    private func share(from source: UIView?) {
        let sheet = UIActivityViewController(activityItems: [SeerrGuide.webGuide], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source ?? view
        sheet.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
        present(sheet, animated: true)
    }
}

/// A command to type on the Plex computer: monospaced on a raised card, wrapping anywhere, with a button that copies it.
struct GuideCommandConfiguration: UIContentConfiguration {
    var command: String
    var copied: Bool
    var onCopy: () -> Void

    func makeContentView() -> UIView & UIContentView {
        GuideCommandView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> GuideCommandConfiguration {
        self
    }
}

final class GuideCommandView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = UIView()
    private let label = UILabel()
    private let button = UIButton(configuration: .plain())

    init(configuration: GuideCommandConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
        card.backgroundColor = Theme.Color.surfaceRaised
        card.layer.cornerRadius = Theme.Radius.m
        card.layer.cornerCurve = .continuous
        label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            (self?.configuration as? GuideCommandConfiguration)?.onCopy()
        }, for: .primaryActionTriggered)
        let row = UIStackView(arrangedSubviews: [label, button])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            card.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
        ])
    }

    private func apply() {
        guard let configuration = configuration as? GuideCommandConfiguration else { return }
        label.text = configuration.command
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: configuration.copied ? "checkmark" : "doc.on.doc")
        config.title = configuration.copied ? SeerrGuide.copied : SeerrGuide.copy
        config.imagePadding = 4
        config.buttonSize = .small
        config.baseForegroundColor = Theme.Color.accentText
        button.configuration = config
        button.accessibilityIdentifier = "seerrGuide.copy"
        label.accessibilityLabel = configuration.command
    }
}
