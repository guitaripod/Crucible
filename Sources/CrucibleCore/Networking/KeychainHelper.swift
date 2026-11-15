import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(os)
import os
#endif

/// Where Crucible keeps its secrets (tokens, keys) by name: the Keychain on Apple platforms; on Linux the store the app
/// installs (the Secret Service), or a file only the user can read until it does.
package protocol SecretStoring: Sendable {
    func save(key: String, value: String)
    func load(key: String) -> String?
    func delete(key: String)
    func deleteAll()
}

package enum KeychainHelper {
    private static let installed = OSAllocatedUnfairLock<(any SecretStoring)?>(initialState: nil)

    /// Replaces the platform's default store, before anything is read.
    package static func install(_ store: any SecretStoring) {
        installed.withLock { $0 = store }
    }

    private static var store: any SecretStoring {
        installed.withLock { $0 } ?? defaultStore
    }

    #if canImport(Security)
    private static let defaultStore: any SecretStoring = KeychainSecretStore()
    #else
    private static let defaultStore: any SecretStoring = FileSecretStore(url: AppPlatform.persistentDirectory.appendingPathComponent("secrets.json"))
    #endif

    static func save(key: String, value: String) { store.save(key: key, value: value) }
    static func load(key: String) -> String? { store.load(key: key) }
    static func delete(key: String) { store.delete(key: key) }
    static func deleteAll() { store.deleteAll() }
}

#if canImport(Security)
struct KeychainSecretStore: SecretStoring {
    private static let service = "com.guitaripod.crucible"

    func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif

/// Secrets as a JSON object in a file only its owner can read or write, for a platform with no keychain installed.
package final class FileSecretStore: SecretStoring, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    package init(url: URL) {
        self.url = url
    }

    package func save(key: String, value: String) {
        mutate { $0[key] = value }
    }

    package func load(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return read()[key]
    }

    package func delete(key: String) {
        mutate { $0[key] = nil }
    }

    package func deleteAll() {
        mutate { $0 = [:] }
    }

    private func mutate(_ change: (inout [String: String]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var secrets = read()
        change(&secrets)
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
