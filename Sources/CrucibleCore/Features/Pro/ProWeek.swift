import Foundation
import MidgarCore
import Security

/// A week of Crucible Pro for every viewer who has not bought it, once per device, from the first film or episode they watch
/// to the end. Nothing is charged and nothing renews. When it ends the free app is as it was; titles downloaded during the
/// week stay downloaded.
///
/// The calendar is derived from the start date alone, so a relaunch, a reinstall or a clock change all agree.
package enum ProWeek {
    package static let length: TimeInterval = 7 * 86_400

    package enum Phase: Equatable, Sendable {
        case notStarted
        case active(endsAt: Date)
        case ended(at: Date)

        package var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    /// A clock wound back before the start reads as the week's first moment, never as a week that has not begun.
    package static func phase(start: Date?, now: Date) -> Phase {
        guard let start else { return .notStarted }
        let end = start.addingTimeInterval(length)
        return max(0, now.timeIntervalSince(start)) < length ? .active(endsAt: end) : .ended(at: end)
    }

    /// Whole days left until `end`, counting a part day as a day, so the last day reads as the last day and never as zero.
    package static func daysLeft(until end: Date, now: Date) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// "Pro week · 5 days left", or "Pro week · last day" on the last one.
    package static func daysLeftText(until end: Date, now: Date = Date()) -> String {
        let days = daysLeft(until: end, now: now)
        return days == 1 ? String(localized: "Pro week · last day") : String(localized: "Pro week · \(days) days left")
    }

    /// "Saturday, November 9" in the viewer's language and calendar, for the end of the week.
    package static func endDateText(_ end: Date) -> String {
        end.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// The line the paywall leads with around the week: that it just ended, or until when it runs. Nil outside the week, where the
    /// paywall says why it opened instead.
    package static func paywallLine(followsProWeek: Bool, endsAt: Date?, isTV: Bool = AppPlatform.isTV) -> String? {
        if followsProWeek {
            return isTV
                ? String(localized: "Your Pro week has ended.")
                : String(localized: "Your Pro week has ended. Titles you downloaded stay on this iPhone.")
        }
        guard let endsAt else { return nil }
        let date = endDateText(endsAt)
        return String(localized: "Your Pro week runs until \(date). Crucible Pro keeps everything open after that.")
    }
}

/// Where the Pro Week's dates and its two notes live. The live store keeps the start in the keychain as well, because a
/// reinstall would otherwise hand out another week; the item is never synchronizable, so a week belongs to one device. The
/// demo's store keeps its own week under keys of its own, only in the defaults, so it can be forgotten. Tests and previews get
/// a store of their own that forgets everything with the process.
package final class ProWeekStore: @unchecked Sendable {
    private static let keychainService = "com.guitaripod.crucible.proweek"
    private static let keychainAccount = "start"
    private static let demoPrefix = "demo."

    private let defaults: UserDefaults
    private let usesKeychain: Bool
    private let suiteName: String?
    private let keyPrefix: String

    private init(defaults: UserDefaults, usesKeychain: Bool, suiteName: String?, keyPrefix: String = "") {
        self.defaults = defaults
        self.usesKeychain = usesKeychain
        self.suiteName = suiteName
        self.keyPrefix = keyPrefix
    }

    private var startKey: String { keyPrefix + "proWeek.start" }
    private var announcedKey: String { keyPrefix + "proWeek.announced" }
    private var endNoticeKey: String { keyPrefix + "proWeek.endNoticeShown" }

    deinit {
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
    }

    /// The app's store: the keychain first, then the defaults copy.
    package static func live(defaults: UserDefaults = .standard) -> ProWeekStore {
        ProWeekStore(defaults: defaults, usesKeychain: true, suiteName: nil)
    }

    /// The demo's own week, in the defaults only.
    package static func demo(defaults: UserDefaults = .standard) -> ProWeekStore {
        ProWeekStore(defaults: defaults, usesKeychain: false, suiteName: nil, keyPrefix: demoPrefix)
    }

    /// A store in a throwaway defaults suite that is removed with the store.
    package static func ephemeral() -> ProWeekStore {
        let suite = "crucible.proweek.\(UUID().uuidString)"
        return ProWeekStore(defaults: UserDefaults(suiteName: suite) ?? .standard, usesKeychain: false, suiteName: suite)
    }

    package var start: Date? {
        let stored = usesKeychain ? Self.keychainStart() : nil
        guard let seconds = stored ?? (defaults.object(forKey: startKey) as? Double) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    package func saveStart(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: startKey)
        if usesKeychain { Self.writeKeychainStart(date.timeIntervalSince1970) }
    }

    package var wasAnnounced: Bool {
        get { defaults.bool(forKey: announcedKey) }
        set { defaults.set(newValue, forKey: announcedKey) }
    }

    package var endNoticeShown: Bool {
        get { defaults.bool(forKey: endNoticeKey) }
        set { defaults.set(newValue, forKey: endNoticeKey) }
    }

    /// Forgets the demo's week and its two notes when the demo ends. A store that keeps its week in the keychain, the device's, is
    /// left alone.
    package func forgetDemoWeek() {
        guard !usesKeychain else { return }
        for key in [startKey, announcedKey, endNoticeKey] {
            defaults.removeObject(forKey: key)
        }
    }

    #if DEBUG
    /// Forgets the week, its two notes and the keychain item, for debug launches that restage or remove the week.
    package func reset() {
        for key in [startKey, announcedKey, endNoticeKey] {
            defaults.removeObject(forKey: key)
        }
        if usesKeychain { SecItemDelete(Self.baseQuery as CFDictionary) }
    }
    #endif

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func keychainStart() -> Double? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Double(text)
    }

    /// Adds the item once; a start already stored is never moved.
    private static func writeKeychainStart(_ seconds: Double) {
        var query = baseQuery
        query[kSecValueData as String] = Data(String(seconds).utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            MidgarLog.notice("Pro Week start not written to the keychain: \(status)", category: .store)
        }
    }
}
