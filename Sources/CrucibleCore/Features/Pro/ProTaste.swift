import Foundation
import MidgarCore
#if canImport(Security)
import Security
#endif

/// The AI features a viewer without Crucible Pro gets one real answer from: the picks of What to Watch and a recap
/// written from episode descriptions.
package enum ProTasteFeature: String, CaseIterable, Sendable {
    case whatToWatch
    case writtenRecap

    /// The Pro feature the answer belongs to, which the paywall names when the sealed part is reached for.
    package var proFeature: ProFeature {
        switch self {
        case .whatToWatch: return .whatToWatch
        case .writtenRecap: return .previouslyOn
        }
    }
}

/// How much of an AI answer a viewer gets right now.
package enum ProTasteAccess: Equatable, Sendable {
    /// Pro, a Pro Week, the demo's unlocked library or a source build: the whole answer.
    case whole
    /// No Pro, and this device has not had its one answer from the feature yet: the model answers for real and the
    /// screen shows the first part, with the rest sealed until Pro is on.
    case taste
    /// No Pro and the taste is used: asking opens the paywall.
    case locked
}

/// A taste of Crucible's AI for a viewer who has not bought Pro: one real answer from each feature, once per device.
/// The model answers in full from the viewer's own library; the screen shows the first pick or how the recap begins
/// and seals the rest, and a purchase opens it at once without asking again. The paywall then follows something the
/// viewer has seen work on their own films and series, instead of standing in front of it. Afterwards the feature is
/// locked as every Pro feature is.
///
/// Like the Pro Week's start, a used taste is kept in the keychain as well as the defaults, never synchronizable, so a
/// reinstall hands out no second one. The demo keeps its own under keys of its own, only in the defaults, so they can
/// be forgotten. Tests and previews get a store of their own that forgets everything with the process.
package final class ProTasteStore: @unchecked Sendable {
    private static let keychainService = "com.guitaripod.crucible.taste"
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

    deinit {
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
    }

    /// The app's store: the keychain first, then the defaults copy.
    package static func live(defaults: UserDefaults = .standard) -> ProTasteStore {
        ProTasteStore(defaults: defaults, usesKeychain: true, suiteName: nil)
    }

    /// The demo's own tastes, in the defaults only.
    package static func demo(defaults: UserDefaults = .standard) -> ProTasteStore {
        ProTasteStore(defaults: defaults, usesKeychain: false, suiteName: nil, keyPrefix: demoPrefix)
    }

    /// A store in a throwaway defaults suite that is removed with the store.
    package static func ephemeral() -> ProTasteStore {
        let suite = "crucible.taste.\(UUID().uuidString)"
        return ProTasteStore(defaults: UserDefaults(suiteName: suite) ?? .standard, usesKeychain: false, suiteName: suite)
    }

    private func key(_ feature: ProTasteFeature) -> String {
        keyPrefix + "proTaste." + feature.rawValue
    }

    package func isUsed(_ feature: ProTasteFeature) -> Bool {
        if usesKeychain, Self.keychainHolds(feature) { return true }
        return defaults.bool(forKey: key(feature))
    }

    package func markUsed(_ feature: ProTasteFeature) {
        defaults.set(true, forKey: key(feature))
        if usesKeychain { Self.writeKeychain(feature) }
    }

    /// Forgets the demo's tastes when the demo ends. A store that keeps its tastes in the keychain, the device's, is
    /// left alone.
    package func forgetDemoTastes() {
        guard !usesKeychain else { return }
        for feature in ProTasteFeature.allCases {
            defaults.removeObject(forKey: key(feature))
        }
    }

    #if DEBUG
    /// Forgets every taste and its keychain item, for debug launches that restage them.
    package func reset() {
        for feature in ProTasteFeature.allCases {
            defaults.removeObject(forKey: key(feature))
            #if canImport(Security)
            if usesKeychain { SecItemDelete(Self.query(feature) as CFDictionary) }
            #endif
        }
    }
    #endif

    #if canImport(Security)
    private static func query(_ feature: ProTasteFeature) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: feature.rawValue,
        ]
    }

    private static func keychainHolds(_ feature: ProTasteFeature) -> Bool {
        var query = query(feature)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Adds the item once; one already there is left as it is.
    private static func writeKeychain(_ feature: ProTasteFeature) {
        var query = query(feature)
        query[kSecValueData as String] = Data("1".utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            MidgarLog.notice("Taste of \(feature.rawValue) not written to the keychain: \(status)", category: .store)
        }
    }
    #else
    private static func keychainHolds(_ feature: ProTasteFeature) -> Bool { false }
    private static func writeKeychain(_ feature: ProTasteFeature) {}
    #endif
}
