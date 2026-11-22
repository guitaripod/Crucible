import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The schedule being edited, shared by the week and day screens (`TVSportsScheduleEditor`): every change shows on both at
/// once and goes to the server a moment after the last one.
@MainActor
final class SportsScheduleEditor {
    let source: any SportsSource
    let settings: SportsSettings
    private(set) var schedule: SportsSchedule
    private var saved: SportsSchedule
    private var saveTask: Task<Void, Never>?
    private let onSaved: (SportsSchedule?) -> Void
    /// Called after every change, so each screen showing the schedule draws it again.
    var observers: [ObjectIdentifier: () -> Void] = [:]
    /// The window to say so in when the server refuses a change.
    weak var window: Window?

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
        return show(changed)
    }

    /// Shows `changed` everywhere and saves it soon; false when it has no hour.
    @discardableResult
    func show(_ changed: SportsSchedule) -> Bool {
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
            if let window { AlertView.notice(title: SportsCopy.schedule, message: error.message, in: window) }
        }
    }
}

/// The week's hours as a grid (`SportsWeekGridView`): a row per day in the order the desktop's calendar starts its week, a
/// column per hour, the chosen hours filled and now outlined on the server's clock. A click chooses an hour, a drag paints
/// many, and a click on a day or an hour's heading chooses all of it.
@MainActor
final class SportsWeekGrid: View {
    private var schedule = SportsSchedule.always
    var now: (day: Int, hour: Int)? { didSet { setNeedsDisplay() } }
    /// Called for every hour the owner changes, and once when a click or drag ends.
    var onChange: ((SportsSchedule) -> Void)?
    var onCommit: ((SportsSchedule) -> Void)?

    private let order = SportsCopy.weekOrder
    private var painting: Bool?
    private var lastCell: (row: Int, column: Int)?
    private var hovered: Int?

    /// Shows `schedule` unless the owner is painting, so a refresh never pulls the grid out from under the pointer.
    func show(_ schedule: SportsSchedule) {
        guard painting == nil, schedule != self.schedule else { return }
        self.schedule = schedule
        setNeedsDisplay()
    }

    override var isPointerInteractive: Bool { onChange != nil }
    override var cursor: Cursor { onChange != nil ? .pointer : .default }
    override var accessibilityLabel: String? { SportsCopy.hoursHeader }
    override var accessibilityValue: String? {
        order.map { "\(SportsCopy.weekday($0)): \(SportsCopy.dayHours(schedule, day: $0))" }.joined(separator: "; ")
    }

    private var font: Font { Theme.current.type.footnote }
    private var textScale: Float { window?.scale ?? 1 }
    private var dayColumnWidth: Float {
        let widest = order.map { TextLayout(SportsCopy.weekday($0, short: true), font: font, scale: textScale).size.width }.max() ?? 40
        return widest.rounded(.up) + Theme.current.metrics.tv(16)
    }
    private var headerHeight: Float { TextLayout("0", font: font, scale: textScale).size.height + Theme.current.metrics.tv(8) }
    private var rowHeight: Float { max(Theme.current.metrics.tv(44), TextLayout("0", font: font, scale: textScale).size.height * 1.6) }
    private var gap: Float { max(2, Theme.current.metrics.tv(4)) }
    private var cellWidth: Float { (bounds.width - dayColumnWidth) / 24 }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: headerHeight + 7 * rowHeight)
    }

    private func cellRect(row: Int, column: Int) -> Rect {
        Rect(x: dayColumnWidth + Float(column) * cellWidth + gap / 2, y: headerHeight + Float(row) * rowHeight + gap / 2,
             width: cellWidth - gap, height: rowHeight - gap)
    }

    private enum Spot {
        case cell(row: Int, column: Int)
        case day(row: Int)
        case hour(column: Int)
    }

    private func spot(at point: Point) -> Spot? {
        let row = Int(((point.y - headerHeight) / rowHeight).rounded(.down))
        let column = Int(((point.x - dayColumnWidth) / cellWidth).rounded(.down))
        switch (point.x < dayColumnWidth, point.y < headerHeight) {
        case (true, true): return nil
        case (true, false): return (0..<7).contains(row) ? .day(row: row) : nil
        case (false, true): return (0..<24).contains(column) ? .hour(column: column) : nil
        case (false, false): return (0..<7).contains(row) && (0..<24).contains(column) ? .cell(row: row, column: column) : nil
        }
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        for hour in stride(from: 0, to: 24, by: 6) {
            let label = TextLayout(SportsCopy.hour(hour, short: true), font: font, scale: textScale)
            context.text(label, at: Point(x: dayColumnWidth + Float(hour) * cellWidth + gap / 2, y: 0), color: palette.labelSecondary)
        }
        let corner = min(cellWidth, rowHeight) * 0.22
        for (row, day) in order.enumerated() {
            let name = TextLayout(SportsCopy.weekday(day, short: true), font: font, scale: textScale)
            let top = headerHeight + Float(row) * rowHeight
            context.text(name, at: Point(x: 0, y: top + (rowHeight - name.size.height) / 2), color: hovered == row ? palette.label : palette.labelSecondary)
            for hour in 0..<24 {
                context.fill(cellRect(row: row, column: hour), radius: corner, color: schedule.allows(day: day, hour: hour) ? palette.accent : palette.surfaceHigh)
            }
        }
        if let now, let row = order.firstIndex(of: now.day), (0..<24).contains(now.hour) {
            let rect = cellRect(row: row, column: now.hour)
            context.stroke(Rect(x: rect.x - 1, y: rect.y - 1, width: rect.width + 2, height: rect.height + 2), radius: corner + 1, width: 2, color: palette.label)
        }
    }

    override func pointerMoved(to point: Point) {
        guard onChange != nil else { return }
        let row: Int? = if case .day(let row)? = spot(at: point) { row } else { nil }
        if row != hovered {
            hovered = row
            setNeedsDisplay()
        }
    }

    override func pointerExited() {
        hovered = nil
        setNeedsDisplay()
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary, onChange != nil, let spot = spot(at: point) else { return false }
        switch spot {
        case .cell(let row, let column):
            painting = !schedule.allows(day: order[row], hour: column)
            lastCell = nil
            paint(row: row, column: column)
        case .day(let row):
            let day = order[row]
            change { $0.set(day: day, to: $0.ranges(day: day) == [0..<24] ? 0 : SportsSchedule.wholeDay) }
        case .hour(let column):
            change { $0.set(hour: column, to: !$0.allDays(hour: column)) }
        }
        return true
    }

    override func pointerDragged(to point: Point) {
        guard painting != nil else { return }
        let row = min(6, max(0, Int(((point.y - headerHeight) / rowHeight).rounded(.down))))
        let column = min(23, max(0, Int(((point.x - dayColumnWidth) / cellWidth).rounded(.down))))
        paint(row: row, column: column)
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard painting != nil else { return }
        painting = nil
        lastCell = nil
        onCommit?(schedule)
    }

    private func change(_ edit: (inout SportsSchedule) -> Void) {
        var changed = schedule
        edit(&changed)
        guard changed != schedule else { return }
        schedule = changed
        setNeedsDisplay()
        onChange?(changed)
        onCommit?(changed)
    }

    /// Paints every cell from the last one painted to this one, so a quick drag leaves no gaps.
    private func paint(row: Int, column: Int) {
        guard let target = painting else { return }
        let start = lastCell ?? (row, column)
        let steps = max(abs(row - start.row), abs(column - start.column), 1)
        var changed = false
        for step in 0...steps {
            let fraction = Float(step) / Float(steps)
            let cellRow = start.row + Int((Float(row - start.row) * fraction).rounded())
            let cellColumn = start.column + Int((Float(column - start.column) * fraction).rounded())
            let day = order[cellRow]
            if schedule.allows(day: day, hour: cellColumn) != target {
                schedule.set(day: day, hour: cellColumn, to: target)
                changed = true
            }
        }
        lastCell = (row, column)
        guard changed else { return }
        setNeedsDisplay()
        onChange?(schedule)
    }
}

/// The context column of the schedule screens: a raised panel with a heading, the week's grid, which the pointer paints,
/// and under it what the focused row does, or why there is nothing to save.
@MainActor
final class SportsScheduleStage: View {
    let grid = SportsWeekGrid()
    private var heading = ""
    private var body = ""
    private var warning: String?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(grid)
    }

    func show(heading: String, body: String, warning: String? = nil) {
        self.heading = heading
        self.body = body
        self.warning = warning
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override var accessibilityExposesChildren: Bool { true }
    override var accessibilityLabel: String? { [heading, warning, body].compactMap { $0 }.joined(separator: ". ") }

    private var inset: Float { Theme.current.metrics.tv(36) }
    private var spacing: Float { Theme.current.metrics.tv(24) }
    private var textScale: Float { window?.scale ?? 1 }

    private struct Texts {
        var heading: TextLayout
        var warning: TextLayout?
        var body: TextLayout?
    }

    private func texts(width: Float) -> Texts {
        let type = Theme.current.type
        return Texts(
            heading: TextLayout(heading, font: Font(size: type.title3.size, weight: .bold), maxWidth: width, maxLines: 2, scale: textScale),
            warning: warning.map { TextLayout($0, font: type.cardSubtitle, maxWidth: width, maxLines: 3, scale: textScale) },
            body: body.isEmpty ? nil : TextLayout(body, font: type.cardSubtitle, maxWidth: width, maxLines: 16, scale: textScale)
        )
    }

    private func gridHeight(_ width: Float) -> Float { grid.sizeThatFits(Size(width: width, height: 0)).height }

    override func sizeThatFits(_ size: Size) -> Size {
        let width = size.width - inset * 2
        let parts = texts(width: width)
        var height = inset * 2 + parts.heading.size.height + spacing + gridHeight(width)
        if let warning = parts.warning { height += spacing + warning.size.height }
        if let body = parts.body { height += spacing + body.size.height }
        return Size(width: size.width, height: height)
    }

    override func layoutSubviews() {
        let width = bounds.width - inset * 2
        let top = inset + texts(width: width).heading.size.height + spacing
        grid.frame = Rect(x: inset, y: top, width: width, height: gridHeight(width))
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        context.fill(bounds, radius: theme.metrics.radiusL, color: theme.palette.surfaceRaised)
        let parts = texts(width: bounds.width - inset * 2)
        context.text(parts.heading, at: Point(x: inset, y: inset), color: theme.palette.label)
        var y = grid.frame.maxY
        if let warning = parts.warning {
            y += spacing
            context.text(warning, at: Point(x: inset, y: y), color: Color(hex: 0xFF9F0A))
            y += warning.size.height
        }
        if let body = parts.body {
            y += spacing
            context.text(body, at: Point(x: inset, y: y), color: theme.palette.labelSecondary)
        }
    }
}

/// Library Research › Schedule on Linux (`TVSportsScheduleViewController`): the ready-made schedules, then each day of the
/// week with its hours; the week's grid beside them takes the pointer.
@MainActor
final class SportsScheduleScreen: SettingsScaffold {
    private enum ID {
        static let preset = "schedule.preset."
        static let custom = "schedule.custom"
        static let day = "schedule.day."
    }

    private let editor: SportsScheduleEditor
    private let stage = SportsScheduleStage()
    private var focusedID: String?
    private var warning: String?

    init(source: any SportsSource, settings: SportsSettings, onSaved: @escaping (SportsSchedule?) -> Void) {
        editor = SportsScheduleEditor(source: source, settings: settings, onSaved: onSaved)
        super.init(title: SportsCopy.schedule)
        pinsContext = true
        installContext(stage)
        stage.grid.onChange = { [weak self] changed in self?.painted(changed) }
        stage.grid.onCommit = { [weak self] changed in self?.painted(changed) }
        editor.observers[ObjectIdentifier(self)] = { [weak self] in self?.render() }
        render()
    }

    override func screenDidAppear() {
        editor.window = window
        render()
    }

    override func screenWillDisappear() {
        editor.flush()
    }

    /// A stroke on the grid: shown at once, saved once there is an hour to run in, else the warning says why not.
    private func painted(_ changed: SportsSchedule) {
        warning = changed.isEmpty ? SportsCopy.chooseAnHour : nil
        if !editor.show(changed) { refreshStage() }
    }

    private func render() {
        let schedule = editor.schedule
        var rows = SportsSchedule.Preset.allCases.map { preset in
            RowItem(id: ID.preset + preset.rawValue, title: SportsCopy.preset(preset), subtitle: preset == .anyTime ? nil : SportsCopy.summary(preset.schedule), symbol: Symbol(preset.symbol),
                    accessory: schedule.preset == preset ? .checkmark : .none)
        }
        if schedule.preset == nil {
            rows.append(RowItem(id: ID.custom, title: SportsCopy.custom, subtitle: SportsCopy.summary(schedule), symbol: "slider.horizontal.3", accessory: .checkmark, isStatic: true))
        }
        rows += SportsCopy.weekOrder.map { day in
            RowItem(id: ID.day + "\(day)", title: SportsCopy.weekday(day), value: SportsCopy.dayHours(schedule, day: day), symbol: "calendar", accessory: .chevron)
        }
        setRows(rows)
        refreshStage()
    }

    override func rowFocused(_ id: String) {
        focusedID = id
        refreshStage()
    }

    private func refreshStage() {
        stage.grid.show(editor.schedule)
        stage.grid.now = editor.now
        let facts = [SportsCopy.hoursAWeek(editor.schedule.hours), SportsCopy.clockNote(editor.settings)].compactMap { $0 }.joined(separator: " · ")
        let body = (focusedID ?? "").hasPrefix(ID.day) ? facts : "\(facts)\n\n\(SportsCopy.gridHintPointer)\n\n\(SportsCopy.scheduleExplanation)"
        stage.show(heading: SportsCopy.scheduleValue(editor.schedule), body: body, warning: warning)
    }

    override func rowSelected(_ id: String) {
        if id.hasPrefix(ID.preset), let preset = SportsSchedule.Preset(rawValue: String(id.dropFirst(ID.preset.count))) {
            warning = nil
            editor.change { $0 = preset.schedule }
        } else if id.hasPrefix(ID.day), let day = Int(id.dropFirst(ID.day.count)) {
            navigation?.push(SportsDayScreen(editor: editor, day: day))
        }
    }
}

/// One day's hours on Linux (`TVSportsDayViewController`): the whole day or none of it, its hours for other days, then
/// every hour to choose, for a gamepad or the keyboard; the grid beside them still takes the pointer.
@MainActor
final class SportsDayScreen: SettingsScaffold {
    private enum ID {
        static let allDay = "day.allDay"
        static let none = "day.none"
        static let everyDay = "day.everyDay"
        static let weekdays = "day.weekdays"
        static let hour = "day.hour."
    }

    private let editor: SportsScheduleEditor
    private let day: Int
    private let stage = SportsScheduleStage()

    init(editor: SportsScheduleEditor, day: Int) {
        self.editor = editor
        self.day = day
        super.init(title: SportsCopy.weekday(day))
        pinsContext = true
        installContext(stage)
        stage.grid.onChange = { [weak self] changed in self?.editor.show(changed) }
        stage.grid.onCommit = { [weak self] changed in self?.editor.show(changed) }
        editor.observers[ObjectIdentifier(self)] = { [weak self] in self?.render() }
        render()
    }

    override func screenDidAppear() {
        editor.window = window
    }

    override func screenWillDisappear() {
        editor.flush()
    }

    private func render() {
        let schedule = editor.schedule
        let ranges = schedule.ranges(day: day)
        var rows = [
            RowItem(id: ID.allDay, title: SportsCopy.allDay, symbol: "clock.fill", accessory: ranges == [0..<24] ? .checkmark : .none),
            RowItem(id: ID.none, title: SportsCopy.noHours, symbol: "moon", accessory: ranges.isEmpty ? .checkmark : .none),
            RowItem(id: ID.everyDay, title: SportsCopy.sameHoursEveryDay, symbol: "doc.on.doc"),
        ]
        if day < 5 { rows.append(RowItem(id: ID.weekdays, title: SportsCopy.sameHoursWeekdays, symbol: "rectangle.stack")) }
        rows += (0..<24).map { hour in
            RowItem.onOff(id: ID.hour + "\(hour)", title: "\(SportsCopy.hour(hour))–\(SportsCopy.hour(hour + 1))", isOn: schedule.allows(day: day, hour: hour), symbol: "clock")
        }
        setRows(rows)
        stage.grid.show(schedule)
        stage.grid.now = editor.now
        stage.show(heading: SportsCopy.dayHours(schedule, day: day), body: [SportsCopy.dayHint(SportsCopy.weekday(day)), SportsCopy.clockNote(editor.settings)].compactMap { $0 }.joined(separator: "\n\n"))
    }

    override func rowSelected(_ id: String) {
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
        if !accepted, let window { AlertView.notice(title: SportsCopy.schedule, message: SportsCopy.chooseAnHour, in: window) }
    }
}
