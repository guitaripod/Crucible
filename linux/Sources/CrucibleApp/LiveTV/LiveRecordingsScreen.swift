import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Live TV › Recordings: what the server is recording now, what it will record, and the standing rules, each with its
/// way to stop it (cancel one recording, delete a rule).
@MainActor
final class LiveRecordingsScreen: SettingsScaffold {
    private let api: APIClient
    private var scheduled: [ScheduledRecording] = []
    private var rules: [RecordingRule] = []
    private var loadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(api: APIClient) {
        self.api = api
        super.init(title: LiveTVCopy.recordings)
        installContext(ContextPanel(content: .init(symbol: "record.circle", title: LiveTVCopy.recordings, body: LiveTVCopy.recordingNeedsPass)))
        observer = NotificationCenter.default.addObserver(forName: .liveRecordingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    isolated deinit {
        loadTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func screenDidAppear() {
        if scheduled.isEmpty, rules.isEmpty { presentLoadingRows() }
        load()
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    private func load() {
        let api = api
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                async let scheduled = LiveRecordings.scheduled(api: api)
                async let rules = LiveRecordings.rules(api: api)
                let (found, standing) = try await (scheduled, rules)
                guard let self, !Task.isCancelled else { return }
                self.scheduled = found
                self.rules = standing
                self.render()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.presentState(.error(title: LiveTVCopy.recordings, message: LiveTVCopy.recordingError(error), retryTitle: LiveTVCopy.tryAgain,
                                         retry: { [weak self] in self?.load() }))
            }
        }
    }

    private func render() {
        let upcoming = scheduled.filter { $0.status != .complete }
        guard !upcoming.isEmpty || !rules.isEmpty else {
            presentState(.empty(title: LiveTVCopy.noRecordings, message: LiveTVCopy.noRecordingsText, symbol: "record.circle", action: nil))
            return
        }
        var items: [RowItem] = []
        for recording in upcoming {
            let when = recording.start.map { Self.when($0) } ?? ""
            let status: String = switch recording.status {
            case .recording: LiveTVCopy.recordingNow
            case .failed: LiveTVCopy.failedStatus
            default: when
            }
            let subtitle = [recording.episodeTitle, recording.channel].compactMap { $0 }.joined(separator: " · ")
            items.append(RowItem(id: "r.\(recording.id)", title: recording.title, subtitle: subtitle.isEmpty ? nil : subtitle, value: status,
                                 symbol: recording.status == .recording ? "record.circle.fill" : "calendar"))
        }
        for rule in rules {
            items.append(RowItem(id: "s.\(rule.id)", title: rule.title, subtitle: [rule.airings, rule.library].compactMap { $0 }.joined(separator: " · "),
                                 value: rule.isSeries ? LiveTVCopy.recordSeries : LiveTVCopy.recordEpisode, symbol: "repeat"))
        }
        setRows(items)
        presentState(nil)
    }

    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    override func rowSelected(_ id: String) {
        guard let window else { return }
        if id.hasPrefix("r."), let recording = scheduled.first(where: { "r.\($0.id)" == id }) {
            AlertView(title: recording.title, message: recording.episodeTitle, actions: [
                AlertView.Action(LiveTVCopy.cancelRecording, role: .destructive) { [weak self] in self?.perform { try await LiveRecordings.cancel(recording, api: $0) } },
                AlertView.Action(String(localized: "Close"), role: .cancel),
            ]).present(in: window)
        } else if id.hasPrefix("s."), let rule = rules.first(where: { "s.\($0.id)" == id }) {
            AlertView(title: LiveTVCopy.deleteRuleQuestion, message: LiveTVCopy.deleteRuleText, actions: [
                AlertView.Action(LiveTVCopy.deleteRule, role: .destructive) { [weak self] in self?.perform { try await LiveRecordings.deleteRule(rule.id, api: $0) } },
                AlertView.Action(String(localized: "Cancel"), role: .cancel),
            ]).present(in: window)
        }
    }

    private func perform(_ change: @escaping @Sendable (APIClient) async throws -> Void) {
        let api = api
        Task { [weak self] in
            do {
                try await change(api)
            } catch {
                guard let self, let window = self.window else { return }
                AlertView.notice(title: LiveTVCopy.recordingError(error), message: nil, in: window)
            }
        }
    }
}
