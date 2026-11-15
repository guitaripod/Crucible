import CLinuxServices
import CrucibleCore
import Foundation

/// Crucible's secrets (the Plex token, the client identifier) in the desktop's Secret Service, KWallet on Plasma or GNOME
/// Keyring, falling back to the private file store when no service answers (a bare session, a container).
final class SecretServiceStore: SecretStoring, @unchecked Sendable {
    private let fallback: FileSecretStore
    private let lock = NSLock()
    private var serviceAvailable: Bool?

    init(fallback: FileSecretStore) {
        self.fallback = fallback
    }

    /// Whether the Secret Service answered the first lookup; remembered for the process.
    private var usesService: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let serviceAvailable { return serviceAvailable }
        var reachable = false
        let probe = crucible_secret_lookup("probe", &reachable)
        if let probe { crucible_secret_free(probe) }
        serviceAvailable = reachable
        return reachable
    }

    func save(key: String, value: String) {
        guard usesService, crucible_secret_store(key, value) else {
            fallback.save(key: key, value: value)
            return
        }
        fallback.delete(key: key)
    }

    func load(key: String) -> String? {
        guard usesService else { return fallback.load(key: key) }
        var reachable = false
        if let found = crucible_secret_lookup(key, &reachable) {
            defer { crucible_secret_free(found) }
            return String(cString: found)
        }
        if let legacy = fallback.load(key: key), reachable, crucible_secret_store(key, legacy) {
            fallback.delete(key: key)
            return legacy
        }
        return fallback.load(key: key)
    }

    func delete(key: String) {
        if usesService { _ = crucible_secret_clear(key) }
        fallback.delete(key: key)
    }

    func deleteAll() {
        if usesService { _ = crucible_secret_clear_all() }
        fallback.deleteAll()
    }
}
