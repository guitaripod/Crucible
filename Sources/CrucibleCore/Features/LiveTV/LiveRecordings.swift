import Foundation
import MidgarCore

/// A choice the server's subscription template offers for an airing: record this one airing, or every episode of the show.
package struct RecordingOption: Sendable, Hashable, Identifiable {
    package let id: String
    package let title: String
    /// Plex's metadata type of what is recorded: 4 for an airing, 2 for a show, 1 for a film.
    package let type: Int
    /// The pre-encoded hints and parameters the server wants back when the recording is created.
    package let parameters: String
    package let targetLibrarySectionID: Int?
    package let targetSectionLocationID: Int?
    package let librarySectionTitle: String?
    package let isSelected: Bool
    package let settings: [RecordingSetting]

    /// Whether this choice records a whole series rather than one airing.
    package var isSeries: Bool { type == 2 }
}

/// One setting of a recording, with the values the server allows.
package struct RecordingSetting: Sendable, Hashable, Identifiable {
    package struct Choice: Sendable, Hashable {
        package let value: String
        package let title: String
    }

    package let id: String
    package let label: String
    package let summary: String
    package let type: String
    package let value: String
    package let isHidden: Bool
    package let isAdvanced: Bool
    package let choices: [Choice]

    /// The choice the value names, when the setting has choices.
    package var currentChoice: Choice? { choices.first { $0.value == value } }

    package var isBool: Bool { type == "bool" }

    /// "1:New Airings Only|0:New and Repeat Airings" as choices.
    static func choices(from text: String?) -> [Choice] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "|").map { pair in
            let parts = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.first.map(String.init) ?? ""
            return Choice(value: value, title: parts.count > 1 ? String(parts[1]) : value)
        }
    }
}

/// A recording the server has scheduled, is making or failed to make.
package struct ScheduledRecording: Sendable, Hashable, Identifiable {
    package enum Status: String, Sendable {
        case scheduled
        case recording
        case complete
        case failed
        case other
    }

    package let id: String
    package let ruleKey: String?
    package let status: Status
    package let title: String
    package let episodeTitle: String?
    package let start: Date?
    package let end: Date?
    package let channel: String?
    package let image: URL?
    /// How far a recording in progress has come, from 0 to 1.
    package let percent: Double?
}

/// A standing recording rule: a show or a one-off airing the server keeps recording.
package struct RecordingRule: Sendable, Hashable, Identifiable {
    package let id: String
    package let title: String
    package let type: Int
    package let library: String?
    package let airings: String?
    package let storageBytes: Int64?
    package let settings: [RecordingSetting]

    package var isSeries: Bool { type == 2 }
}

/// Recording on the viewer's Plex server: what can be recorded, what is scheduled, and the standing rules. Recording needs
/// Plex Pass on the server owner's account; a server that refuses answers 403 and the caller says why.
package enum LiveRecordings {
    package static func options(for hint: LiveRecordHint, api: APIClient) async throws -> [RecordingOption] {
        let body: PlexLiveContainer<TemplateBody> = try await api.request(.recordingTemplate(guid: hint.guid))
        let subscriptions = (body.MediaContainer.SubscriptionTemplate ?? []).flatMap { $0.MediaSubscription ?? [] }
        return subscriptions.enumerated().compactMap { index, subscription in
            guard let parameters = subscription.parameters, let type = subscription.type else { return nil }
            return RecordingOption(id: "\(index).\(type)", title: subscription.title ?? "", type: type, parameters: parameters,
                                   targetLibrarySectionID: subscription.targetLibrarySectionID, targetSectionLocationID: subscription.targetSectionLocationID,
                                   librarySectionTitle: subscription.librarySectionTitle, isSelected: subscription.selected,
                                   settings: (subscription.Setting ?? []).map(\.setting))
        }
    }

    /// Creates the recording `option` describes, with `values` overriding its settings.
    package static func record(_ option: RecordingOption, values: [String: String] = [:], api: APIClient) async throws {
        try await api.requestConfirmed(.createRecording(query: query(for: option, values: values)))
        await announce()
    }

    /// The query the server takes to create a recording: the template's own parameters, where it goes, and every setting.
    static func query(for option: RecordingOption, values: [String: String]) -> [URLQueryItem] {
        var items = option.parameters.split(separator: "&").compactMap { pair -> URLQueryItem? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first.flatMap({ String($0).removingPercentEncoding }) else { return nil }
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            return URLQueryItem(name: name, value: value)
        }
        if let section = option.targetLibrarySectionID { items.append(URLQueryItem(name: "targetLibrarySectionID", value: String(section))) }
        if let location = option.targetSectionLocationID { items.append(URLQueryItem(name: "targetSectionLocationID", value: String(location))) }
        items.append(URLQueryItem(name: "type", value: String(option.type)))
        items.append(URLQueryItem(name: "includeGrabs", value: "1"))
        for setting in option.settings {
            items.append(URLQueryItem(name: "prefs[\(setting.id)]", value: values[setting.id] ?? setting.value))
        }
        return items
    }

    package static func scheduled(api: APIClient) async throws -> [ScheduledRecording] {
        let body: PlexLiveContainer<ScheduledBody> = try await api.request(.scheduledRecordings)
        let base = await api.baseURL
        return (body.MediaContainer.MediaGrabOperation ?? []).compactMap { $0.recording(base: base) }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    package static func rules(api: APIClient) async throws -> [RecordingRule] {
        let body: PlexLiveContainer<RulesBody> = try await api.request(.recordingRules)
        return (body.MediaContainer.MediaSubscription ?? []).compactMap { subscription in
            guard let key = subscription.key else { return nil }
            return RecordingRule(id: key, title: subscription.title ?? "", type: subscription.type ?? 0, library: subscription.librarySectionTitle,
                                 airings: subscription.airingsType, storageBytes: subscription.storageTotal, settings: (subscription.Setting ?? []).map(\.setting))
        }
    }

    package static func deleteRule(_ key: String, api: APIClient) async throws {
        try await api.requestConfirmed(.deleteRecordingRule(key: key))
        await announce()
    }

    package static func cancel(_ recording: ScheduledRecording, api: APIClient) async throws {
        try await api.requestConfirmed(.cancelRecording(operationID: recording.id))
        await announce()
    }

    @MainActor
    private static func announce() {
        NotificationCenter.default.post(name: .liveRecordingsChanged, object: nil)
    }

    struct SettingEntry: Decodable, Sendable {
        let id: String?
        let label: String?
        let summary: String?
        let type: String?
        let value: String?
        let hidden: Bool
        let advanced: Bool
        let enumValues: String?

        enum CodingKeys: String, CodingKey { case id, label, summary, type, value, hidden, advanced, enumValues }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = PlexLiveLenient.string(container, .id)
            label = try? container.decodeIfPresent(String.self, forKey: .label)
            summary = try? container.decodeIfPresent(String.self, forKey: .summary)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            if let flag = try? container.decodeIfPresent(Bool.self, forKey: .value) {
                value = flag ? "true" : "false"
            } else {
                value = PlexLiveLenient.string(container, .value)
            }
            hidden = PlexLiveLenient.bool(container, .hidden)
            advanced = PlexLiveLenient.bool(container, .advanced)
            enumValues = try? container.decodeIfPresent(String.self, forKey: .enumValues)
        }

        var setting: RecordingSetting {
            RecordingSetting(id: id ?? "", label: label ?? id ?? "", summary: summary ?? "", type: type ?? "text", value: value ?? "",
                             isHidden: hidden, isAdvanced: advanced, choices: RecordingSetting.choices(from: enumValues))
        }
    }

    struct SubscriptionEntry: Decodable, Sendable {
        let key: String?
        let type: Int?
        let title: String?
        let parameters: String?
        let selected: Bool
        let targetLibrarySectionID: Int?
        let targetSectionLocationID: Int?
        let librarySectionTitle: String?
        let airingsType: String?
        let storageTotal: Int64?
        let Setting: [SettingEntry]?

        enum CodingKeys: String, CodingKey {
            case key, type, title, parameters, selected, targetLibrarySectionID, targetSectionLocationID, librarySectionTitle, airingsType, storageTotal, Setting
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = PlexLiveLenient.string(container, .key)
            type = PlexNumber.decode(container, .type, Int.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            parameters = try? container.decodeIfPresent(String.self, forKey: .parameters)
            selected = PlexLiveLenient.bool(container, .selected)
            targetLibrarySectionID = PlexNumber.decode(container, .targetLibrarySectionID, Int.self)
            targetSectionLocationID = PlexNumber.decode(container, .targetSectionLocationID, Int.self)
            librarySectionTitle = try? container.decodeIfPresent(String.self, forKey: .librarySectionTitle)
            airingsType = try? container.decodeIfPresent(String.self, forKey: .airingsType)
            storageTotal = PlexNumber.decode(container, .storageTotal, Int64.self)
            Setting = try? container.decodeIfPresent([SettingEntry].self, forKey: .Setting)
        }
    }

    struct TemplateBody: Decodable, Sendable {
        struct Template: Decodable, Sendable {
            let MediaSubscription: [SubscriptionEntry]?
        }

        let SubscriptionTemplate: [Template]?
    }

    struct RulesBody: Decodable, Sendable {
        let MediaSubscription: [SubscriptionEntry]?
    }

    struct ScheduledBody: Decodable, Sendable {
        struct Operation: Decodable, Sendable {
            let id: String?
            let mediaSubscriptionID: String?
            let status: String?
            let percent: Double?
            let Metadata: PlexLiveAiring?

            enum CodingKeys: String, CodingKey { case id, key, mediaSubscriptionID, status, percent, Metadata }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = PlexLiveLenient.string(container, .id) ?? PlexLiveLenient.string(container, .key)
                mediaSubscriptionID = PlexLiveLenient.string(container, .mediaSubscriptionID)
                status = try? container.decodeIfPresent(String.self, forKey: .status)
                percent = PlexNumber.decode(container, .percent, Double.self)
                Metadata = try? container.decodeIfPresent(PlexLiveAiring.self, forKey: .Metadata)
            }

            func recording(base: URL) -> ScheduledRecording? {
                guard let airing = Metadata else { return nil }
                let program = airing.program(channelID: "", imageBase: base)
                let media = airing.Media?.first
                let identity = id ?? airing.ratingKey ?? UUID().uuidString
                let state: ScheduledRecording.Status = switch status?.lowercased() {
                case "scheduled": .scheduled
                case "inprogress", "in_progress", "recording", "grabbing": .recording
                case "complete", "completed", "done": .complete
                case "error", "failed": .failed
                default: .other
                }
                return ScheduledRecording(id: identity, ruleKey: mediaSubscriptionID, status: state, title: program?.title ?? airing.title ?? "",
                                          episodeTitle: program?.episodeTitle, start: program?.start, end: program?.end,
                                          channel: [media?.channelVcn, media?.channelTitle].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                                          image: program?.image, percent: percent.map { $0 / 100 })
            }
        }

        let MediaGrabOperation: [Operation]?
    }
}

extension Notification.Name {
    /// Posted on the main thread when a recording or rule was made, changed or removed.
    package static let liveRecordingsChanged = Notification.Name("crucible.liveRecordingsChanged")
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
