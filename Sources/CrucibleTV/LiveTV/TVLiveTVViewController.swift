import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import MidgarCore
import UIKit

/// The Live TV tab on the Apple TV: the title with its Beta tag, filter chips (all channels, favourites, recent, each
/// source, Categories), Now, Recordings and Playlists, what the focused airing is, and the guide grid underneath, through
/// which the focus moves airing by airing. Select on an airing that is on plays its channel; on one still to come it
/// offers Record and Watch Live. A long press opens the channel's menu, Play/Pause plays the focused channel.
final class TVLiveTVViewController: TVScreenViewController {
    private let env: TVAppEnvironment
    let guide: LiveTVGuide
    private let layout: LiveGuideLayout
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private let header = UIStackView()
    private let titleLabel = UILabel()
    private lazy var betaTag = BetaTag.button(title: LiveTVCopy.beta, action: UIAction { [weak self] _ in self?.presentBetaNote() })
    private let chips = TVChipRow()
    private let info = TVLiveProgramPanel()
    private var programByItem: [String: LiveProgram] = [:]
    private var channelByItem: [String: LiveChannel] = [:]
    private var scheduledKeys: Set<String> = []
    private lazy var clockSlot = makeTaskSlot()
    private var hasFocusedGuide = false
    nonisolated(unsafe) private var recordingsObserver: (any NSObjectProtocol)?

    init(env: TVAppEnvironment) {
        self.env = env
        guide = LiveTVGuide(context: LiveTVGuide.Context(payload: env.payload))
        let layout = LiveGuideLayout()
        self.layout = layout
        super.init(layout: layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let recordingsObserver { NotificationCenter.default.removeObserver(recordingsObserver) }
    }

    override var hidesBarsWhileScrolling: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.accessibilityIdentifier = "livetv.guide"
        collectionView.remembersLastFocusedIndexPath = true
        configureDataSource()
        chips.onSelect = { [weak self] item in self?.choose(item.id) }
        guide.onChange = { [weak self] in self?.render() }
        guide.onPrograms = { [weak self] _ in self?.applySnapshot() }
        recordingsObserver = NotificationCenter.default.addObserver(forName: .liveRecordingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.loadScheduled() }
        }
        guide.load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateBetaInvitation()
        clockSlot.run { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.applySnapshot()
            }
        }
    }

    override func installViews() {
        titleLabel.text = LiveTVCopy.title
        titleLabel.font = TVFont.screenTitle
        titleLabel.textColor = Theme.Color.label
        titleLabel.accessibilityTraits = .header
        betaTag.accessibilityIdentifier = "livetv.beta"
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, betaTag, UIView()])
        titleRow.axis = .horizontal
        titleRow.spacing = Theme.Space.s
        titleRow.alignment = .center
        header.axis = .vertical
        header.spacing = Theme.Space.s
        header.alignment = .fill
        let chipLine = UIStackView(arrangedSubviews: [chips, UIView()])
        chipLine.axis = .horizontal
        [titleRow, chipLine, info].forEach(header.addArrangedSubview)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        let betaGuide = UIFocusGuide()
        view.addLayoutGuide(betaGuide)
        betaGuide.preferredFocusEnvironments = [betaTag]
        NSLayoutConstraint.activate([
            betaGuide.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            betaGuide.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            betaGuide.topAnchor.constraint(equalTo: titleRow.topAnchor),
            betaGuide.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),
        ])
        super.installViews()
        for constraint in view.constraints where constraint.firstItem === collectionView && constraint.firstAttribute == .top {
            constraint.isActive = false
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: TVMetrics.tabBarClearance),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Space.m),
        ])
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: TVMetrics.topInset, right: 0)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if isShowingState { return super.preferredFocusEnvironments }
        return (dataSource?.snapshot().numberOfItems ?? 0) > 0 ? [collectionView] : [chips]
    }

    // MARK: Header

    private func updateBetaInvitation() {
        betaTag.layer.removeAllAnimations()
        guard !LiveTVPreferences.hasSeenBetaNote, TVMotion.animationsEnabled else { return }
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
        present(TVLiveBetaNoteViewController(), animated: TVMotion.animationsEnabled)
    }

    private func renderChips() {
        var items: [TVChipItem] = guide.filters().filter { filter in
            switch filter {
            case .group, .source: false
            default: true
            }
        }.map { filter in
            TVChipItem(id: Self.chipID(filter), title: guide.title(of: filter), symbol: Self.symbol(of: filter), isSelected: filter == guide.filter)
        }
        if guide.summaries.count > 1 {
            let current: LiveSourceID? = if case .source(let id) = guide.filter { id } else { nil }
            items.append(TVChipItem(id: "sources", title: current.map { guide.title(of: .source($0)) } ?? LiveTVCopy.sources,
                                    symbol: "antenna.radiowaves.left.and.right", isSelected: current != nil))
        }
        if !guide.groups().isEmpty {
            let current: String? = if case .group(let name) = guide.filter { name } else { nil }
            items.append(TVChipItem(id: "categories", title: current ?? LiveTVCopy.categories, symbol: "square.grid.2x2", isSelected: current != nil))
        }
        if guide.canRecord { items.append(TVChipItem(id: "recordings", title: LiveTVCopy.recordings, symbol: "record.circle", isSelected: false)) }
        items.append(TVChipItem(id: "playlists", title: LiveTVCopy.playlists, symbol: "list.bullet", isSelected: false))
        chips.setItems(items)
    }

    private static func chipID(_ filter: LiveTVGuide.Filter) -> String {
        switch filter {
        case .all: "f.all"
        case .favorites: "f.favorites"
        case .recent: "f.recent"
        case .source(let id): "f.source.\(id)"
        case .group(let name): "f.group.\(name)"
        }
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

    private func choose(_ id: String) {
        switch id {
        case "recordings": _ = TVNavigation.push(TVLiveRecordingsViewController(api: env.api), from: self)
        case "playlists": _ = TVNavigation.push(TVLivePlaylistsViewController(showsDestinationSwitch: false), from: self)
        case "categories": presentCategories()
        case "sources": presentSources()
        default:
            if let filter = guide.filters().first(where: { Self.chipID($0) == id }) { guide.filter = filter }
        }
    }

    private func presentSources() {
        let sheet = UIAlertController(title: LiveTVCopy.sources, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: LiveTVCopy.allChannels, style: .default) { [weak self] _ in self?.guide.filter = .all })
        for source in guide.summaries {
            sheet.addAction(UIAlertAction(title: "\(source.title) (\(source.channelCount))", style: .default) { [weak self] _ in
                self?.guide.filter = .source(source.id)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: TVMotion.animationsEnabled)
    }

    private func presentCategories() {
        let sheet = UIAlertController(title: LiveTVCopy.categories, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: LiveTVCopy.allChannels, style: .default) { [weak self] _ in self?.guide.filter = .all })
        for group in guide.groups() {
            sheet.addAction(UIAlertAction(title: "\(group.name) (\(group.count))", style: .default) { [weak self] _ in self?.guide.filter = .group(group.name) })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: TVMotion.animationsEnabled)
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
            view.configure(number: channel.number, title: channel.title, logoURL: channel.logo, isFavorite: self.guide.isFavorite(id))
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
        adopt(dataSource)
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
        renderChips()
        switch guide.state {
        case .loading:
            show(state: .loading(title: nil))
        case .empty:
            show(state: .empty(title: LiveTVCopy.emptyTitle, message: LiveTVCopy.emptyText, symbol: "antenna.radiowaves.left.and.right",
                               action: .init(title: LiveTVCopy.addPlaylist) { [weak self] in
                                   guard let self else { return }
                                   _ = TVNavigation.push(TVLivePlaylistsViewController(showsDestinationSwitch: false), from: self)
                               }))
        case .failed(let message):
            show(state: .error(title: LiveTVCopy.failedTitle, message: message, retryTitle: LiveTVCopy.tryAgain, retry: { [weak self] in self?.guide.load(force: true) }))
        case .ready:
            if guide.visibleChannels.isEmpty, guide.filter == .favorites {
                show(state: .empty(title: LiveTVCopy.favorites, message: LiveTVCopy.noFavoritesText, symbol: "star",
                                   action: .init(title: LiveTVCopy.allChannels) { [weak self] in self?.guide.filter = .all }))
            } else {
                showContent()
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
                    snapshot.appendItems([program.id], toSection: channel.id)
                    programByItem[program.id] = program
                    channelByItem[program.id] = channel
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
            if !self.hasFocusedGuide, !rows.isEmpty {
                self.hasFocusedGuide = true
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }
    }

    override func initialFocusIndexPath() -> IndexPath? {
        let snapshot = dataSource.snapshot()
        let preferred = LiveTVPreferences.recentChannels.first.flatMap { id in snapshot.sectionIdentifiers.firstIndex(of: id) } ?? 0
        guard snapshot.sectionIdentifiers.indices.contains(preferred) else { return nil }
        let items = snapshot.itemIdentifiers(inSection: snapshot.sectionIdentifiers[preferred])
        let now = Date()
        let index = items.firstIndex { programByItem[$0]?.isOn(at: now) == true } ?? 0
        return IndexPath(item: index, section: preferred)
    }

    private func requestVisiblePrograms() {
        let sections = Set(collectionView.indexPathsForVisibleItems.map(\.section))
        let ids = sections.sorted().compactMap { dataSource.sectionIdentifier(for: $0) }
        guide.loadPrograms(for: ids.isEmpty ? Array(guide.visibleChannels.prefix(10).map(\.id)) : ids)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        requestVisiblePrograms()
    }

    private func scrollToNow(animated: Bool) {
        collectionView.setContentOffset(CGPoint(x: layout.offset(showing: LiveGuideMath.slotStart(Date())), y: collectionView.contentOffset.y), animated: animated)
    }

    override func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
        guard let indexPath = context.nextFocusedIndexPath, let item = dataSource.itemIdentifier(for: indexPath), let channel = channelByItem[item] else { return }
        let program = programByItem[item] ?? guide.nowAndNext(channel.id).now
        info.show(channel: channel, program: program, next: program.flatMap { program in guide.programs(of: channel.id).first { $0.start >= program.end } })
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), let channel = channelByItem[item] else { return }
        if let program = programByItem[item], program.start > Date() {
            presentActions(for: channel, program: program)
        } else {
            play(channel)
        }
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath), let channel = channelByItem[item] else { return false }
        play(channel)
        return true
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath), let channel = channelByItem[item] else { return nil }
        let program = programByItem[item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: program?.title ?? channel.numberedTitle, children: self?.actions(for: channel, program: program) ?? [])
        }
    }

    private func actions(for channel: LiveChannel, program: LiveProgram?) -> [UIAction] {
        var items = [UIAction(title: program.map { $0.start > Date() ? LiveTVCopy.watchLive : LiveTVCopy.watch } ?? LiveTVCopy.watch,
                              image: UIImage(systemName: "play.fill")) { [weak self] _ in self?.play(channel) }]
        if let program, program.end > Date(), program.record != nil, guide.source(of: channel)?.records == true {
            items.append(UIAction(title: LiveTVCopy.record, image: UIImage(systemName: "record.circle")) { [weak self] _ in self?.record(program) })
        }
        let favorite = guide.isFavorite(channel.id)
        items.append(UIAction(title: favorite ? LiveTVCopy.removeFavorite : LiveTVCopy.addFavorite, image: UIImage(systemName: favorite ? "star.slash" : "star")) { [weak self] _ in
            self?.guide.toggleFavorite(channel.id)
            if var snapshot = self?.dataSource.snapshot() {
                snapshot.reloadSections([channel.id].filter { snapshot.sectionIdentifiers.contains($0) })
                self?.dataSource.apply(snapshot, animatingDifferences: false)
            }
        })
        return items
    }

    private func presentActions(for channel: LiveChannel, program: LiveProgram) {
        let sheet = UIAlertController(title: program.title, message: "\(channel.numberedTitle) · \(LiveGuideMath.timeRange(program))", preferredStyle: .actionSheet)
        for action in actions(for: channel, program: program) {
            sheet.addAction(UIAlertAction(title: action.title, style: .default) { _ in action.performWithSender(nil, target: nil) })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: TVMotion.animationsEnabled)
    }

    func play(_ channel: LiveChannel) {
        TVLiveTVPlayer.present(channel: channel, guide: guide, from: self)
    }

    // MARK: Recording

    private static func scheduleKey(_ title: String, _ start: Date?) -> String {
        "\(title.lowercased())|\(Int(start?.timeIntervalSince1970 ?? 0) / 60)"
    }

    private func loadScheduled() {
        guard guide.canRecord else { return }
        let api = env.api
        Task { [weak self] in
            guard let recordings = try? await LiveRecordings.scheduled(api: api), let self else { return }
            let keys = Set(recordings.filter { $0.status == .scheduled || $0.status == .recording }.map { Self.scheduleKey($0.title, $0.start) })
            guard keys != self.scheduledKeys else { return }
            self.scheduledKeys = keys
            self.applySnapshot()
        }
    }

    private func record(_ program: LiveProgram) {
        guard let hint = program.record else { return }
        let api = env.api
        Task { [weak self] in
            do {
                let options = try await LiveRecordings.options(for: hint, api: api)
                guard let self else { return }
                let sheet = UIAlertController(title: LiveTVCopy.record, message: program.title, preferredStyle: .actionSheet)
                for option in options {
                    sheet.addAction(UIAlertAction(title: option.isSeries ? LiveTVCopy.recordSeries : LiveTVCopy.recordEpisode, style: .default) { [weak self] _ in
                        self?.schedule(option)
                    })
                }
                sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
                self.present(sheet, animated: TVMotion.animationsEnabled)
            } catch {
                self?.presentAlert(title: LiveTVCopy.recordingError(error))
            }
        }
    }

    private func schedule(_ option: RecordingOption) {
        let api = env.api
        Task { [weak self] in
            do {
                try await LiveRecordings.record(option, api: api)
                self?.presentAlert(title: LiveTVCopy.recordingScheduled, message: option.title)
            } catch {
                self?.presentAlert(title: LiveTVCopy.recordingError(error))
            }
        }
    }
}

/// What the focused airing is, above the guide: the channel, the title, when it airs and what is left, the episode, and
/// what follows.
final class TVLiveProgramPanel: UIStackView {
    private let eyebrow = UILabel()
    private let titleLabel = UILabel()
    private let meta = UILabel()
    private let summary = UILabel()

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Theme.Space.xxs
        alignment = .leading
        eyebrow.font = TVFont.eyebrow
        eyebrow.textColor = Theme.Color.accentText
        titleLabel.font = Theme.Font.title3
        titleLabel.textColor = Theme.Color.label
        meta.font = TVFont.cardSubtitle
        meta.textColor = Theme.Color.labelSecondary
        summary.font = TVFont.screenDetail
        summary.textColor = Theme.Color.labelSecondary
        summary.numberOfLines = 2
        [eyebrow, titleLabel, meta, summary].forEach(addArrangedSubview)
        summary.widthAnchor.constraint(lessThanOrEqualToConstant: TVMetrics.gridWidth * 0.75).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func show(channel: LiveChannel, program: LiveProgram?, next: LiveProgram?) {
        let now = Date()
        eyebrow.text = (program?.isOn(at: now) == true ? "\(LiveTVCopy.live) · " : "") + channel.numberedTitle
        titleLabel.text = program?.title ?? LiveTVCopy.noGuide
        var parts: [String] = []
        if let program {
            parts.append(LiveGuideMath.timeRange(program))
            if program.isOn(at: now) { parts.append(LiveGuideMath.remaining(program, at: now)) }
            if let code = program.episodeCode { parts.append(code) }
            if let episode = program.episodeTitle { parts.append(episode) }
        }
        if let next { parts.append("\(LiveTVCopy.upNext): \(next.title)") }
        meta.text = parts.joined(separator: "  ·  ")
        summary.text = program?.summary
        accessibilityLabel = [eyebrow.text, titleLabel.text, meta.text].compactMap { $0 }.joined(separator: ", ")
    }
}
