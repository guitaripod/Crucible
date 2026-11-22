import CrucibleCore
import CrucibleDesign
import UIKit

/// The schedule being edited on Apple TV, shared by the week and day screens: every change shows on both at once and goes
/// to the server a moment after the last one.
@MainActor
final class TVSportsScheduleEditor {
    let source: any SportsSource
    let settings: SportsSettings
    private(set) var schedule: SportsSchedule
    private var saved: SportsSchedule
    private var saveTask: Task<Void, Never>?
    private let onSaved: (SportsSchedule?) -> Void
    /// Called after every change, so each screen showing the schedule draws it again.
    var observers: [ObjectIdentifier: () -> Void] = [:]
    /// The screen on top, which says so when the server refuses a change.
    weak var presenter: UIViewController?

    init(source: any SportsSource, settings: SportsSettings, onSaved: @escaping (SportsSchedule?) -> Void) {
        self.source = source
        self.settings = settings
        self.onSaved = onSaved
        schedule = settings.schedule ?? .always
        saved = schedule
    }

    var now: (day: Int, hour: Int)? {
        guard let day = settings.weekday, let hour = settings.hour else { return nil }
        return (day, hour)
    }

    /// Applies `edit`, unless it would leave no hour at all, which research could never run in.
    @discardableResult
    func change(_ edit: (inout SportsSchedule) -> Void) -> Bool {
        var changed = schedule
        edit(&changed)
        guard !changed.isEmpty else { return false }
        guard changed != schedule else { return true }
        schedule = changed
        observers.values.forEach { $0() }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
        return true
    }

    /// Sends what is pending now, as the owner leaves the schedule.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in await self?.save() }
    }

    private func save() async {
        saveTask = nil
        let wanted = schedule
        guard wanted != saved else { return }
        do throws(CompanionError) {
            try await source.scheduleSports(wanted.isAlways ? nil : wanted)
            saved = wanted
            onSaved(wanted.isAlways ? nil : wanted)
        } catch {
            presenter?.presentAlert(title: SportsCopy.schedule, message: error.message)
        }
    }
}

/// The context column of the schedule screens: a heading with what the focused row does, over the week's grid.
private final class TVScheduleContext: UIStackView {
    let heading: TVSettingsHeading
    let grid = SportsWeekGridView(editable: false)

    init(title: String) {
        heading = TVSettingsHeading(title: title)
        super.init(frame: .zero)
        axis = .vertical
        spacing = Theme.Space.l
        addArrangedSubview(heading)
        addArrangedSubview(grid)
        grid.accessibilityIdentifier = "sports.schedule.grid"
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func show(_ editor: TVSportsScheduleEditor, body: String?) {
        grid.show(editor.schedule)
        grid.now = editor.now
        heading.setBody(body)
    }
}

/// Library Research › Schedule on Apple TV: the ready-made schedules, then each day of the week with its hours; the week's
/// grid stands beside them.
final class TVSportsScheduleViewController: TVSettingsScaffold {
    private enum ID {
        static let preset = "schedule.preset."
        static let day = "schedule.day."
    }

    private let editor: TVSportsScheduleEditor
    private let context = TVScheduleContext(title: SportsCopy.schedule)
    private var focusedID: String?

    init(source: any SportsSource, settings: SportsSettings, onSaved: @escaping (SportsSchedule?) -> Void) {
        editor = TVSportsScheduleEditor(source: source, settings: settings, onSaved: onSaved)
        super.init()
        title = SportsCopy.schedule
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContext(context)
        editor.observers[ObjectIdentifier(self)] = { [weak self] in self?.render() }
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        editor.presenter = self
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { editor.flush() }
    }

    override var preferredFocusRowID: String? {
        editor.schedule.preset.map { ID.preset + $0.rawValue }
    }

    private func render() {
        let schedule = editor.schedule
        var rows = SportsSchedule.Preset.allCases.map { preset in
            TVRowItem(id: ID.preset + preset.rawValue, title: SportsCopy.preset(preset), subtitle: preset == .anyTime ? nil : SportsCopy.summary(preset.schedule), symbol: preset.symbol,
                      accessory: schedule.preset == preset ? .checkmark : .none)
        }
        if schedule.preset == nil {
            rows.append(TVRowItem(id: "schedule.custom", title: SportsCopy.custom, subtitle: SportsCopy.summary(schedule), symbol: "slider.horizontal.3", accessory: .checkmark, isStatic: true))
        }
        rows += SportsCopy.weekOrder.map { day in
            TVRowItem(id: ID.day + "\(day)", title: SportsCopy.weekday(day), value: SportsCopy.dayHours(schedule, day: day), symbol: "calendar", accessory: .chevron)
        }
        setRows(rows)
        refreshContext()
    }

    override func rowDidFocus(_ id: String?) {
        focusedID = id
        refreshContext()
    }

    private func refreshContext() {
        let id = focusedID ?? ""
        let facts = [SportsCopy.hoursAWeek(editor.schedule.hours), SportsCopy.clockNote(editor.settings)].compactMap { $0 }.joined(separator: " · ")
        let body = id.hasPrefix(ID.day) ? facts : "\(SportsCopy.scheduleExplanation)\n\n\(facts)"
        context.show(editor, body: body)
    }

    override func rowDidSelect(_ id: String) {
        if id.hasPrefix(ID.preset), let preset = SportsSchedule.Preset(rawValue: String(id.dropFirst(ID.preset.count))) {
            editor.change { $0 = preset.schedule }
        } else if id.hasPrefix(ID.day), let day = Int(id.dropFirst(ID.day.count)) {
            TVNavigation.push(TVSportsDayViewController(editor: editor, day: day), from: self)
        }
    }
}

/// One day's hours on Apple TV: the whole day or none of it, its hours for other days, then every hour to choose.
final class TVSportsDayViewController: TVSettingsScaffold {
    private enum ID {
        static let allDay = "day.allDay"
        static let none = "day.none"
        static let everyDay = "day.everyDay"
        static let weekdays = "day.weekdays"
        static let hour = "day.hour."
    }

    private let editor: TVSportsScheduleEditor
    private let day: Int
    private let context: TVScheduleContext

    init(editor: TVSportsScheduleEditor, day: Int) {
        self.editor = editor
        self.day = day
        context = TVScheduleContext(title: SportsCopy.weekday(day))
        super.init()
        title = SportsCopy.weekday(day)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContext(context)
        editor.observers[ObjectIdentifier(self)] = { [weak self] in self?.render() }
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        editor.presenter = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { editor.observers[ObjectIdentifier(self)] = nil }
    }

    override var preferredFocusRowID: String? {
        ID.hour + "\(editor.schedule.ranges(day: day).first?.lowerBound ?? 0)"
    }

    private func render() {
        let schedule = editor.schedule
        let whole = schedule.ranges(day: day) == [0..<24]
        var rows = [
            TVRowItem(id: ID.allDay, title: SportsCopy.allDay, symbol: "clock.fill", accessory: whole ? .checkmark : .none),
            TVRowItem(id: ID.none, title: SportsCopy.noHours, symbol: "moon", accessory: schedule.ranges(day: day).isEmpty ? .checkmark : .none),
            TVRowItem(id: ID.everyDay, title: SportsCopy.sameHoursEveryDay, symbol: "doc.on.doc"),
        ]
        if day < 5 { rows.append(TVRowItem(id: ID.weekdays, title: SportsCopy.sameHoursWeekdays, symbol: "rectangle.stack")) }
        rows += (0..<24).map { hour in
            let on = schedule.allows(day: day, hour: hour)
            return TVRowItem(id: ID.hour + "\(hour)", title: "\(SportsCopy.hour(hour))–\(SportsCopy.hour(hour + 1))", value: on ? String(localized: "On") : String(localized: "Off"),
                             symbol: on ? "checkmark.circle.fill" : "circle", accessory: .none)
        }
        setRows(rows)
        let facts = [SportsCopy.dayHours(schedule, day: day), SportsCopy.clockNote(editor.settings)].compactMap { $0 }.joined(separator: " · ")
        context.show(editor, body: "\(SportsCopy.dayHint(SportsCopy.weekday(day)))\n\n\(facts)")
    }

    override func rowDidSelect(_ id: String) {
        let accepted: Bool
        switch id {
        case ID.allDay: accepted = editor.change { $0.set(day: day, to: SportsSchedule.wholeDay) }
        case ID.none: accepted = editor.change { $0.set(day: day, to: 0) }
        case ID.everyDay: accepted = editor.change { $0.copy(day: day, to: 0..<7) }
        case ID.weekdays: accepted = editor.change { $0.copy(day: day, to: 0..<5) }
        case _ where id.hasPrefix(ID.hour):
            guard let hour = Int(id.dropFirst(ID.hour.count)) else { return }
            accepted = editor.change { $0.set(day: day, hour: hour, to: !$0.allows(day: day, hour: hour)) }
        default: return
        }
        if !accepted { presentAlert(title: SportsCopy.schedule, message: SportsCopy.chooseAnHour) }
    }
}
