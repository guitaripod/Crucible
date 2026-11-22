import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The Live TV tab on the iPhone and the iPad: the title with its Beta tag, a filter menu (all channels, favourites, recent,
/// each source, each category) and a menu for Playlists, Recordings and Now, what the selected airing is, and the guide
/// grid. Tapping an airing that is on plays its channel; one still to come offers Record (on a tuner) and Watch Live. A
/// long press offers the channel's actions.
final class LiveTVViewController: UIViewController, UICollectionViewDelegate {
    private let api: APIClient
    let guide: LiveTVGuide
    private let layout = LiveGuideLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private let info = LiveProgramStrip()
    private let state = LiveStateView()
    private var programByItem: [String: LiveProgram] = [:]
    private var channelByItem: [String: LiveChannel] = [:]
    private var clock: Task<Void, Never>?
    private var scheduledKeys: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var selectedItem: String?
    private var hasScrolledToNow = false
    private lazy var searchResults = LiveSearchResultsController(guide: guide)
    private lazy var betaTag = BetaTag.button(title: LiveTVCopy.beta, action: UIAction { [weak self] _ in self?.presentBetaNote() })

    init(context: LiveTVGuide.Context, api: APIClient) {
        self.api = api
        guide = LiveTVGuide(context: context)
        super.init(nibName: nil, bundle: nil)
        title = LiveTVCopy.title
        tabBarItem.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        clock?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = titleView()
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: LiveTVCopy.title, image: UIImage(systemName: "ellipsis.circle"), menu: actionsMenu()),
            UIBarButtonItem(title: LiveTVCopy.filter, image: UIImage(systemName: "line.3.horizontal.decrease.circle"), menu: filterMenu()),
        ]
        navigationItem.rightBarButtonItems?.first?.accessibilityIdentifier = "livetv.actions"
        navigationItem.rightBarButtonItems?.last?.accessibilityIdentifier = "livetv.filter"
        installSearch()

        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.delegate = self
        collectionView.isDirectionalLockEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.accessibilityIdentifier = "livetv.guide"
        let stack = UIStackView(arrangedSubviews: [info, collectionView])
        stack.axis = .vertical
        stack.spacing = Theme.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        state.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(state)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.xs),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Space.xs),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            state.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            state.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            state.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            state.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        info.onTap = { [weak self] in self?.playSelection() }
        configureDataSource()
        guide.onChange = { [weak self] in self?.render() }
        guide.onPrograms = { [weak self] ids in self?.programsArrived(ids) }
        observers.append(NotificationCenter.default.addObserver(forName: .liveRecordingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadScheduled() }
        })
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: LiveTVViewController, _: UITraitCollection) in
            controller.info.isHidden = controller.traitCollection.verticalSizeClass == .compact
        }
        info.isHidden = traitCollection.verticalSizeClass == .compact
        guide.load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startClock()
        betaTag.isSelected = false
        updateBetaInvitation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.cancel()
        clock = nil
    }

    // MARK: Search

    /// Search in the navigation bar, a button that opens a field on iOS 26 and later, with the results over the guide.
    private func installSearch() {
        searchResults.onPlay = { [weak self] channel in self?.play(channel) }
        searchResults.onAiring = { [weak self] channel, program, source in self?.presentActions(for: channel, program: program, from: source) }
        let search = UISearchController(searchResultsController: searchResults)
        search.searchResultsUpdater = searchResults
        search.searchBar.placeholder = LiveTVCopy.searchPlaceholder
        search.searchBar.accessibilityIdentifier = "livetv.search"
        navigationItem.searchController = search
        if #available(iOS 26.0, *) {
            navigationItem.preferredSearchBarPlacement = .integratedButton
        } else {
            navigationItem.hidesSearchBarWhenScrolling = true
        }
        definesPresentationContext = true
    }

    /// The controller to present from: the search, while its results are up, else this one.
    private var presenter: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    // MARK: Header

    private func titleView() -> UIView {
        let label = UILabel()
        label.text = LiveTVCopy.title
        label.font = Theme.Font.headline
        label.textColor = Theme.Color.label
        label.accessibilityTraits = .header
        betaTag.accessibilityIdentifier = "livetv.beta"
        betaTag.accessibilityLabel = LiveTVCopy.betaTitle
        let stack = UIStackView(arrangedSubviews: [label, betaTag])
        stack.axis = .horizontal
        stack.spacing = Theme.Space.xs
        stack.alignment = .center
        return stack
    }

    /// The Beta tag glows until the note has been read once.
    private func updateBetaInvitation() {
        betaTag.layer.removeAllAnimations()
        guard !LiveTVPreferences.hasSeenBetaNote, !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.55
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        betaTag.layer.add(pulse, forKey: "invite")
    }

    private func presentBetaNote() {
        LiveTVPreferences.hasSeenBetaNote = true
        updateBetaInvitation()
        let note = LiveBetaNoteViewController()
        note.modalPresentationStyle = .popover
        note.popoverPresentationController?.sourceView = betaTag
        note.popoverPresentationController?.sourceRect = betaTag.bounds
        note.popoverPresentationController?.permittedArrowDirections = [.up]
        note.popoverPresentationController?.delegate = note
        present(note, animated: true)
    }

    private func filterMenu() -> UIMenu {
        UIMenu(title: LiveTVCopy.filter, children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            var primary: [UIMenuElement] = []
            var groups: [UIMenuElement] = []
            for filter in self.guide.filters() {
                let action = UIAction(title: self.guide.title(of: filter), image: Self.symbol(of: filter).flatMap { UIImage(systemName: $0) },
                                      state: filter == self.guide.filter ? .on : .off) { [weak self] _ in
                    Haptics.selection()
                    self?.guide.filter = filter
                }
                if case .group = filter { groups.append(action) } else { primary.append(action) }
            }
            var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: primary)]
            if !groups.isEmpty { children.append(UIMenu(title: LiveTVCopy.categories, image: UIImage(systemName: "square.grid.2x2"), children: groups)) }
            completion(children)
        }])
    }

    private func actionsMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            var items: [UIMenuElement] = [
                UIAction(title: LiveTVCopy.jumpToNow, image: UIImage(systemName: "clock")) { [weak self] _ in self?.scrollToNow(animated: true) },
            ]
            if self.guide.canRecord {
                items.append(UIAction(title: LiveTVCopy.recordings, image: UIImage(systemName: "record.circle")) { [weak self] _ in self?.openRecordings() })
            }
            items.append(UIAction(title: LiveTVCopy.playlists, image: UIImage(systemName: "list.bullet")) { [weak self] _ in self?.openPlaylists(adding: false) })
            items.append(UIAction(title: LiveTVCopy.refreshPlaylists, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.guide.load(force: true) })
            completion(items)
        }])
    }

    private static func symbol(of filter: LiveTVGuide.Filter) -> String? {
        switch filter {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .recent: "clock.arrow.circlepath"
        case .source: "antenna.radiowaves.left.and.right"
        case .group: nil
        }
    }

    // MARK: Data

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<LiveProgramCell, String> { [weak self] cell, _, item in
            cell.program = self?.configuration(for: item)
            cell.accessibilityIdentifier = "livetv.program"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        let channel = UICollectionView.SupplementaryRegistration<LiveChannelHeaderView>(elementKind: LiveGuideLayout.channelKind) { [weak self] view, _, indexPath in
            guard let self, let id = self.dataSource.sectionIdentifier(for: indexPath.section), let channel = self.guide.channel(id: id) else { return }
            let label = LiveChannelLabel(channel)
            view.configure(number: label.number, title: label.name, logoURL: channel.logo, isFavorite: self.guide.isFavorite(id), tags: label.tags)
        }
        let time = UICollectionView.SupplementaryRegistration<LiveTimeHeaderView>(elementKind: LiveGuideLayout.timeKind) { [weak self] view, _, indexPath in
            guard let self else { return }
            view.configure(LiveGuideMath.slotLabel(self.layout.slotStart(indexPath.item)))
        }
        let corner = UICollectionView.SupplementaryRegistration<LiveCornerView>(elementKind: LiveGuideLayout.cornerKind) { _, _, _ in }
        let now = UICollectionView.SupplementaryRegistration<LiveNowLineView>(elementKind: LiveGuideLayout.nowKind) { _, _, _ in }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            switch kind {
            case LiveGuideLayout.channelKind: collectionView.dequeueConfiguredReusableSupplementary(using: channel, for: indexPath)
            case LiveGuideLayout.timeKind: collectionView.dequeueConfiguredReusableSupplementary(using: time, for: indexPath)
            case LiveGuideLayout.cornerKind: collectionView.dequeueConfiguredReusableSupplementary(using: corner, for: indexPath)
            default: collectionView.dequeueConfiguredReusableSupplementary(using: now, for: indexPath)
            }
        }
    }

    private func configuration(for item: String) -> LiveProgramContentConfiguration {
        let now = Date()
        guard let program = programByItem[item] else {
            let loading = channelByItem[item].map { guide.programs[$0.id] == nil } ?? true
            return LiveProgramContentConfiguration(title: loading ? LiveTVCopy.loadingGuide : LiveTVCopy.noGuide, isPlaceholder: true)
        }
        let detail = [program.episodeCode, program.episodeTitle].compactMap { $0 }.joined(separator: " · ")
        return LiveProgramContentConfiguration(title: program.title, detail: detail.isEmpty ? LiveGuideMath.timeRange(program) : detail,
                                               progress: program.isOn(at: now) ? program.progress(at: now) : nil, isPast: program.end <= now,
                                               isNew: program.isNew || program.isPremiere,
                                               isRecording: scheduledKeys.contains(Self.scheduleKey(program.title, program.start)))
    }

    private func render() {
        switch guide.state {
        case .loading:
            state.show(.loading)
        case .empty:
            state.show(.message(title: LiveTVCopy.emptyTitle, text: LiveTVCopy.emptyText, symbol: "antenna.radiowaves.left.and.right",
                                action: (LiveTVCopy.addPlaylist, { [weak self] in self?.openPlaylists(adding: true) })))
        case .failed(let message):
            state.show(.message(title: LiveTVCopy.failedTitle, text: message, symbol: "exclamationmark.triangle",
                                action: (LiveTVCopy.tryAgain, { [weak self] in self?.guide.load(force: true) })))
        case .ready:
            if guide.visibleChannels.isEmpty, guide.filter == .favorites {
                state.show(.message(title: LiveTVCopy.favorites, text: LiveTVCopy.noFavoritesText, symbol: "star",
                                    action: (LiveTVCopy.allChannels, { [weak self] in self?.guide.filter = .all })))
            } else {
                state.show(nil)
            }
        }
        applySnapshot()
        loadScheduled()
    }

    private func applySnapshot() {
        let now = Date()
        layout.origin = LiveGuideMath.slotStart(now)
        layout.hours = LiveTVGuide.guideHours
        layout.now = now
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        var rows: [[DateInterval]] = []
        programByItem = [:]
        channelByItem = [:]
        let window = DateInterval(start: layout.origin, duration: LiveTVGuide.guideHours * 3600)
        for channel in guide.visibleChannels {
            snapshot.appendSections([channel.id])
            let programs = guide.programs(of: channel.id).filter { $0.end > window.start && $0.start < window.end }
            if programs.isEmpty {
                let item = "\(channel.id)#none"
                snapshot.appendItems([item], toSection: channel.id)
                channelByItem[item] = channel
                rows.append([window])
            } else {
                var spans: [DateInterval] = []
                for program in programs {
                    let item = program.id
                    snapshot.appendItems([item], toSection: channel.id)
                    programByItem[item] = program
                    channelByItem[item] = channel
                    spans.append(DateInterval(start: max(program.start, window.start), end: min(program.end, window.end)))
                }
                rows.append(spans)
            }
        }
        layout.rows = rows
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.requestVisiblePrograms()
            if !self.hasScrolledToNow, !rows.isEmpty {
                self.hasScrolledToNow = true
                self.selectInitialRow()
            }
        }
        if selectedItem.map({ channelByItem[$0] == nil }) ?? true {
            let recent = LiveTVPreferences.recentChannels.first.flatMap { id in snapshot.sectionIdentifiers.contains(id) ? id : nil }
            let section = recent ?? snapshot.sectionIdentifiers.first
            selectedItem = section.flatMap { id in
                let items = snapshot.itemIdentifiers(inSection: id)
                return items.first { programByItem[$0]?.isOn(at: now) == true } ?? items.first
            }
        }
        if let selectedItem { showInfo(for: selectedItem) }
    }

    private func programsArrived(_ ids: Set<String>) {
        if navigationItem.searchController?.isActive == true { searchResults.refresh() }
        applySnapshot()
    }

    private func requestVisiblePrograms() {
        let sections = Set(collectionView.indexPathsForVisibleSupplementaryElements(ofKind: LiveGuideLayout.channelKind).map(\.section)
            + collectionView.indexPathsForVisibleItems.map(\.section))
        let ids = sections.sorted().compactMap { dataSource.sectionIdentifier(for: $0) }
        let fallback = ids.isEmpty ? Array(guide.visibleChannels.prefix(14).map(\.id)) : ids
        guide.loadPrograms(for: fallback)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        requestVisiblePrograms()
    }

    private func selectInitialRow() {
        scrollToNow(animated: false)
        guard let recent = LiveTVPreferences.recentChannels.first, let section = guide.visibleChannels.firstIndex(where: { $0.id == recent }) else { return }
        let rowTop = Theme.LiveGuide.headerHeight + CGFloat(section) * (Theme.LiveGuide.rowHeight + Theme.LiveGuide.rowSpacing)
        let y = max(rowTop - Theme.LiveGuide.headerHeight - collectionView.adjustedContentInset.top, -collectionView.adjustedContentInset.top)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: false)
    }

    private func scrollToNow(animated: Bool) {
        let x = layout.offset(showing: LiveGuideMath.slotStart(Date()))
        collectionView.setContentOffset(CGPoint(x: x - collectionView.adjustedContentInset.left, y: collectionView.contentOffset.y), animated: animated)
    }

    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let origin = LiveGuideMath.slotStart(Date())
                if origin != self.layout.origin { self.applySnapshot() } else {
                    self.layout.now = Date()
                    var snapshot = self.dataSource.snapshot()
                    snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { self.programByItem[$0]?.isOn(at: Date().addingTimeInterval(-60)) == true })
                    await self.dataSource.apply(snapshot, animatingDifferences: false)
                }
            }
        }
    }

    // MARK: Selection

    private func showInfo(for item: String) {
        guard let channel = channelByItem[item] else { return }
        let program = programByItem[item] ?? guide.nowAndNext(channel.id).now
        let next = program.flatMap { program in guide.programs(of: channel.id).first { $0.start >= program.end } }
        info.show(channel: channel, program: program, next: next)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath), let channel = channelByItem[item] else { return }
        selectedItem = item
        showInfo(for: item)
        Haptics.selection()
        if let program = programByItem[item], program.start > Date() {
            presentActions(for: channel, program: program, from: collectionView.cellForItem(at: indexPath))
        } else {
            play(channel)
        }
    }

    private func playSelection() {
        guard let selectedItem, let channel = channelByItem[selectedItem] else { return }
        play(channel)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath), let channel = channelByItem[item] else { return nil }
        let program = programByItem[item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: program?.title ?? channel.numberedTitle, children: self?.actions(for: channel, program: program, source: nil) ?? [])
        }
    }

    private func actions(for channel: LiveChannel, program: LiveProgram?, source: UIView?) -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: program.map { $0.start > Date() ? LiveTVCopy.watchLive : LiveTVCopy.watch } ?? LiveTVCopy.watch, image: UIImage(systemName: "play.fill")) { [weak self] _ in
                self?.play(channel)
            },
        ]
        if let program, program.end > Date(), program.record != nil, guide.source(of: channel)?.records == true {
            items.append(UIAction(title: LiveTVCopy.record, image: UIImage(systemName: "record.circle")) { [weak self] _ in self?.record(program, source: source) })
        }
        let favorite = guide.isFavorite(channel.id)
        items.append(UIAction(title: favorite ? LiveTVCopy.removeFavorite : LiveTVCopy.addFavorite, image: UIImage(systemName: favorite ? "star.slash" : "star")) { [weak self] _ in
            Haptics.selection()
            self?.guide.toggleFavorite(channel.id)
            self?.reloadChannelHeaders()
        })
        return items
    }

    private func reloadChannelHeaders() {
        var snapshot = dataSource.snapshot()
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func presentActions(for channel: LiveChannel, program: LiveProgram, from cell: UIView?) {
        let sheet = UIAlertController(title: program.title, message: "\(channel.numberedTitle) · \(LiveGuideMath.timeRange(program))", preferredStyle: .actionSheet)
        for element in actions(for: channel, program: program, source: cell) {
            guard let action = element as? UIAction else { continue }
            sheet.addAction(UIAlertAction(title: action.title, style: .default) { _ in action.performWithSender(nil, target: nil) })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let presenter = presenter
        sheet.popoverPresentationController?.sourceView = cell ?? presenter.view
        sheet.popoverPresentationController?.sourceRect = cell?.bounds ?? presenter.view.bounds
        presenter.present(sheet, animated: true)
    }

    func play(_ channel: LiveChannel) {
        LiveTVPlayerPresenter.present(channel: channel, guide: guide, from: presenter)
    }

    // MARK: Recording

    private static func scheduleKey(_ title: String, _ start: Date?) -> String {
        "\(title.lowercased())|\(Int(start?.timeIntervalSince1970 ?? 0) / 60)"
    }

    private func loadScheduled() {
        guard guide.canRecord else { return }
        let api = self.api
        Task { [weak self] in
            guard let recordings = try? await LiveRecordings.scheduled(api: api), let self else { return }
            let keys = Set(recordings.filter { $0.status == .scheduled || $0.status == .recording }.map { Self.scheduleKey($0.title, $0.start) })
            guard keys != self.scheduledKeys else { return }
            self.scheduledKeys = keys
            self.applySnapshot()
        }
    }

    private func record(_ program: LiveProgram, source: UIView?) {
        guard let hint = program.record else { return }
        let api = self.api
        Task { [weak self] in
            do {
                let options = try await LiveRecordings.options(for: hint, api: api)
                guard let self else { return }
                let sheet = UIAlertController(title: LiveTVCopy.record, message: program.title, preferredStyle: .actionSheet)
                for option in options {
                    let title = option.isSeries ? LiveTVCopy.recordSeries : LiveTVCopy.recordEpisode
                    sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.schedule(option) })
                }
                sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                sheet.popoverPresentationController?.sourceView = source ?? self.view
                sheet.popoverPresentationController?.sourceRect = source?.bounds ?? self.view.bounds
                self.present(sheet, animated: true)
            } catch {
                self?.alert(LiveTVCopy.recordingError(error))
            }
        }
    }

    private func schedule(_ option: RecordingOption) {
        let api = self.api
        Task { [weak self] in
            do {
                try await LiveRecordings.record(option, api: api)
                Haptics.success()
                self?.alert(LiveTVCopy.recordingScheduled, message: option.title)
            } catch {
                self?.alert(LiveTVCopy.recordingError(error))
            }
        }
    }

    private func alert(_ title: String, message: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    // MARK: Navigation

    private func openRecordings() {
        navigationController?.pushViewController(LiveRecordingsViewController(api: api), animated: true)
    }

    func openPlaylists(adding: Bool) {
        let playlists = LivePlaylistsViewController(showsDestinationSwitch: false)
        navigationController?.pushViewController(playlists, animated: true)
        if adding { playlists.presentAdd() }
    }
}

/// What the selected airing is: the channel, the title, the time and what is left, the episode and what follows. Tapping it
/// plays the channel.
final class LiveProgramStrip: UIControl {
    var onTap: (() -> Void)?
    private let eyebrow = UILabel()
    private let titleLabel = UILabel()
    private let meta = UILabel()
    private let nextLabel = UILabel()
    private let live = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        live.text = " \(LiveTVCopy.live) "
        live.font = Theme.Font.caption2
        live.textColor = .white
        live.backgroundColor = Theme.Color.destructive
        live.layer.cornerRadius = 4
        live.clipsToBounds = true
        eyebrow.font = Theme.Font.caption1
        eyebrow.textColor = Theme.Color.accentText
        titleLabel.font = Theme.Font.headline
        titleLabel.textColor = Theme.Color.label
        meta.font = Theme.Font.footnote
        meta.textColor = Theme.Color.labelSecondary
        nextLabel.font = Theme.Font.caption1Regular
        nextLabel.textColor = Theme.Color.labelTertiary
        [eyebrow, titleLabel, meta, nextLabel].forEach { $0.adjustsFontForContentSizeCategory = true }
        let top = UIStackView(arrangedSubviews: [live, eyebrow])
        top.spacing = Theme.Space.xs
        top.alignment = .center
        let stack = UIStackView(arrangedSubviews: [top, titleLabel, meta, nextLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.xxs),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.xs),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xxs),
        ])
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "livetv.info"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(channel: LiveChannel, program: LiveProgram?, next upcoming: LiveProgram?) {
        let now = Date()
        eyebrow.text = channel.numberedTitle
        titleLabel.text = program?.title ?? LiveTVCopy.noGuide
        var parts: [String] = []
        if let program {
            parts.append(LiveGuideMath.timeRange(program))
            if program.isOn(at: now) { parts.append(LiveGuideMath.remaining(program, at: now)) }
            if let code = program.episodeCode { parts.append(code) }
            if let episode = program.episodeTitle { parts.append(episode) }
        }
        meta.text = parts.joined(separator: " · ")
        meta.isHidden = parts.isEmpty
        nextLabel.text = upcoming.map { "\(LiveTVCopy.upNext): \($0.title) · \(LiveGuideMath.slotLabel($0.start))" }
        nextLabel.isHidden = upcoming == nil
        live.isHidden = program?.isOn(at: now) != true
        accessibilityLabel = [channel.numberedTitle, titleLabel.text, meta.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = LiveTVCopy.watch
    }
}

/// Loading, empty and failed states over the guide.
final class LiveStateView: UIView {
    enum State {
        case loading
        case message(title: String, text: String, symbol: String, action: (String, () -> Void)?)
    }

    private let spinner = UIActivityIndicatorView(style: .large)
    private let stack = UIStackView()
    private let image = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let button = UIButton(configuration: .filled())
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.canvas
        image.tintColor = Theme.Color.labelTertiary
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        titleLabel.font = Theme.Font.title3
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        textLabel.font = Theme.Font.body
        textLabel.textColor = Theme.Color.labelSecondary
        textLabel.textAlignment = .center
        textLabel.numberOfLines = 0
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Theme.Color.accent
        configuration.baseForegroundColor = Theme.Color.onAccent
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.alignment = .center
        [image, titleLabel, textLabel, button].forEach(stack.addArrangedSubview)
        stack.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.xl),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: State?) {
        guard let state else {
            isHidden = true
            spinner.stopAnimating()
            return
        }
        isHidden = false
        switch state {
        case .loading:
            stack.isHidden = true
            spinner.startAnimating()
        case .message(let title, let text, let symbol, let action):
            spinner.stopAnimating()
            stack.isHidden = false
            image.image = UIImage(systemName: symbol)
            titleLabel.text = title
            textLabel.text = text
            button.isHidden = action == nil
            button.configuration?.title = action?.0
            self.action = action?.1
        }
    }
}
