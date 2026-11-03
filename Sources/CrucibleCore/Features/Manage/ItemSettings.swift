import Foundation
import MidgarCore

/// One of the settings the server keeps for a single show, the ones Plex calls a show's advanced settings: the order its
/// episodes come in, whether its seasons show, the audio and subtitle languages everyone gets, what happens to watched
/// episodes. Labels and choices come from the server, in its words.
package struct ItemSetting: Sendable, Hashable, Identifiable {
    package struct Choice: Sendable, Hashable {
        package let value: String
        package let title: String
    }

    package let id: String
    package let label: String
    package let summary: String?
    package let type: String
    package let value: String
    package let defaultValue: String
    package let choices: [Choice]

    package var isToggle: Bool { type == "bool" }

    package var isOn: Bool { Self.truthy(value) }

    /// What the setting is set to, the way the list shows it.
    package var valueTitle: String {
        if isToggle {
            return isOn ? String(localized: "On") : String(localized: "Off")
        }
        return choices.first { $0.value == value }?.title ?? value
    }

    package var isChanged: Bool { value != defaultValue }

    package init(id: String, label: String, summary: String?, type: String, value: String, defaultValue: String, choices: [Choice]) {
        self.id = id
        self.label = label
        self.summary = summary
        self.type = type
        self.value = value
        self.defaultValue = defaultValue
        self.choices = choices
    }

    /// The value to send for a toggle switched to `on`, in the form the server used for this setting.
    package func toggleValue(_ on: Bool) -> String {
        if value == "true" || value == "false" || defaultValue == "true" || defaultValue == "false" {
            return on ? "true" : "false"
        }
        return on ? "1" : "0"
    }

    static func truthy(_ text: String) -> Bool {
        text == "1" || text.lowercased() == "true"
    }
}

/// The per-show settings of the server, which only its owner may change, and which apply to everyone who watches the show.
package enum ItemSettings {
    /// The settings worth a row: ones with a list of choices and on/off switches the server does not hide.
    package static func load(ratingKey: String, api: APIClient) async throws -> [ItemSetting] {
        let container: PreferencesContainer = try await api.request(.itemPreferences(ratingKey: ratingKey))
        return container.settings.compactMap(\.setting)
    }

    package static func set(_ setting: ItemSetting, to value: String, ratingKey: String, api: APIClient) async throws {
        do {
            try await api.requestConfirmed(.setItemPreferences(ratingKey: ratingKey, values: [setting.id: value]))
        } catch {
            MidgarLog.error("Setting \(setting.id) for \(ratingKey) failed: \(error.localizedDescription)", category: .networking)
            throw error
        }
        await api.invalidate(ratingKey: ratingKey)
    }

    /// Plex lists a setting's choices as `value:title` pairs joined by `|`, such as `-1:Library default|0:Oldest first`.
    package static func choices(from enumValues: String?) -> [ItemSetting.Choice] {
        guard let enumValues, !enumValues.isEmpty else { return [] }
        return enumValues.split(separator: "|").compactMap { pair -> ItemSetting.Choice? in
            let parts = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return ItemSetting.Choice(value: String(parts[0]), title: String(parts[1]))
        }
    }
}

/// `includePreferences=1` puts the settings under the title (`Metadata[0].Preferences.Setting`); some servers put them on the
/// container itself. Values arrive as strings, numbers or booleans.
private struct PreferencesContainer: Decodable {
    let settings: [RawSetting]

    private struct Body: Decodable {
        let Metadata: [Item]?
        let Preferences: Group?
    }

    private struct Item: Decodable {
        let Preferences: Group?
    }

    private struct Group: Decodable {
        let Setting: [RawSetting]?
    }

    private enum Keys: String, CodingKey { case MediaContainer }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let body = try container.decode(Body.self, forKey: .MediaContainer)
        settings = body.Metadata?.first?.Preferences?.Setting ?? body.Preferences?.Setting ?? []
    }
}

private struct RawSetting: Decodable {
    let id: String
    let label: String?
    let summary: String?
    let type: String?
    let value: String?
    let defaultValue: String?
    let enumValues: String?
    let hidden: Bool

    private enum Keys: String, CodingKey {
        case id, label, summary, type, value, enumValues, hidden
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        value = Self.text(container, .value)
        defaultValue = Self.text(container, .defaultValue)
        enumValues = try? container.decodeIfPresent(String.self, forKey: .enumValues)
        hidden = Self.text(container, .hidden).map(ItemSetting.truthy) ?? false
    }

    private static func text(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) { return string }
        if let bool = try? container.decodeIfPresent(Bool.self, forKey: key) { return bool ? "true" : "false" }
        if let int = try? container.decodeIfPresent(Int.self, forKey: key) { return String(int) }
        if let double = try? container.decodeIfPresent(Double.self, forKey: key) { return String(double) }
        return nil
    }

    var setting: ItemSetting? {
        guard !hidden, let label, !label.isEmpty else { return nil }
        let type = type ?? "text"
        let choices = ItemSettings.choices(from: enumValues)
        guard type == "bool" || !choices.isEmpty else { return nil }
        let value = value ?? defaultValue ?? ""
        return ItemSetting(
            id: id,
            label: label,
            summary: summary?.isEmpty == true ? nil : summary,
            type: type,
            value: value,
            defaultValue: defaultValue ?? value,
            choices: choices
        )
    }
}
