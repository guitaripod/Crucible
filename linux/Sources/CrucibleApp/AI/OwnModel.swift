import CrucibleCore
import Foundation

/// The person's own model (D1, D38): an OpenAI-compatible address, the model to ask there and, when the server wants one,
/// a key. What to Watch and recaps run on it; Crucible for Linux never calls Midgar's hosted model. The address and the
/// model are settings; the key lives in the desktop's secret store.
@MainActor
enum OwnModel {
    private static let addressKey = "ownModel.address"
    private static let modelKey = "ownModel.model"
    private static let secretKey = "ownModel.key"

    static var address: URL? {
        UserDefaults.standard.string(forKey: addressKey).flatMap(URL.init(string:))
    }

    static var model: String? {
        UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var hasKey: Bool { KeychainHelper.load(key: secretKey)?.isEmpty == false }

    static var isConfigured: Bool { address != nil && model != nil }

    /// Saves the address a person typed, reading a bare host as http on its own port ("192.168.1.20:8080").
    static func setAddress(_ typed: String) -> Bool {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: addressKey)
            install()
            return true
        }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else {
            return false
        }
        UserDefaults.standard.set(url.absoluteString, forKey: addressKey)
        install()
        return true
    }

    static func setModel(_ typed: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: modelKey) } else { UserDefaults.standard.set(trimmed, forKey: modelKey) }
        install()
    }

    static func setKey(_ typed: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { KeychainHelper.delete(key: secretKey) } else { KeychainHelper.save(key: secretKey, value: trimmed) }
        install()
    }

    /// Forgets the address, the model and the key.
    static func remove() {
        UserDefaults.standard.removeObject(forKey: addressKey)
        UserDefaults.standard.removeObject(forKey: modelKey)
        KeychainHelper.delete(key: secretKey)
        install()
    }

    /// Puts the model behind What to Watch and recaps when one is set up, or takes it away when not.
    static func install() {
        guard let brain = brain else {
            HostedBrain.remove()
            return
        }
        HostedBrain.install(brain)
    }

    /// The configured model as a brain, or nil when the address or the model is missing.
    static var brain: OpenAICompatibleBrain? {
        guard let address, let model, let prompts = OwnModelPrompts.bundled else { return nil }
        return OpenAICompatibleBrain(address: address, model: model, key: KeychainHelper.load(key: secretKey), prompts: prompts)
    }
}

/// The alias instructions and reply shapes bundled from `tools/ai`.
enum OwnModelPrompts {
    static let bundled: OpenAICompatiblePrompts? = {
        guard let url = Bundle.module.url(forResource: "aliases", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return OpenAICompatiblePrompts(aliasesJSON: data) { alias in
            Bundle.module.url(forResource: alias, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
    }()
}
