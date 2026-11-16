import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The words of the person's own model on Linux, where Crucible's AI is theirs (D1).
enum OwnModelCopy {
    static let title = String(localized: "Your Own Model", comment: "Linux settings for the OpenAI-compatible model What to Watch and recaps run on")
    static let explanation = String(localized: "What to Watch and recaps run on a model you choose: any OpenAI-compatible address, such as llama.cpp, Ollama, LM Studio or vLLM on your network, or a hosted service with its key. It gets your request and the titles, years, genres, lengths, ratings and watched state of your films and series. Nothing else leaves this computer.", comment: "Explanation in the Linux settings for the person's own model")
    static let address = String(localized: "Address", comment: "Setting: the web address of the person's own model, e.g. http://192.168.1.20:8080/v1")
    static let model = String(localized: "Model", comment: "Setting: the name of the model to ask at the person's own address")
    static let key = String(localized: "API Key", comment: "Setting: the key the person's own model server asks for")
    static let notSet = String(localized: "Not Set", comment: "Value of a setting nobody has filled in")
    static let saved = String(localized: "Saved", comment: "Value of the API key setting once a key is stored")
    static let check = String(localized: "Check the Model", comment: "Row that asks the person's own model a test question")
    static let checking = String(localized: "Checking…", comment: "While Crucible asks the person's own model a test question")
    static let answered = String(localized: "Your model answered.", comment: "Alert after a successful test of the person's own model")
    static let remove = String(localized: "Remove Model", comment: "Row that forgets the address, model and key of the person's own model")
    static let badAddress = String(localized: "Couldn’t Use That Address", comment: "Alert when the typed model address is not a web address")
    static let addressHint = String(localized: "Type an address such as http://192.168.1.20:8080/v1.", comment: "How to type the address of the person's own model")
    static let addressPlaceholder = "http://192.168.1.20:8080/v1"
    static let modelPlaceholder = String(localized: "The model's name, e.g. qwen3", comment: "Placeholder of the model name field")
    static let keyPlaceholder = String(localized: "Leave empty when the server needs none", comment: "Placeholder of the API key field")
    static let askExplanation = String(localized: "Say what you feel like and Crucible picks from your own library. Your words and the titles, years, genres, lengths, ratings and watched state of your films and series go to your model to choose. Nothing else leaves this computer.", comment: "What to Watch on Linux: what is sent to the person's own model")

    /// Why the person's model gave no answer, in place of the hosted model's reasons.
    static func refusal(_ error: HostedBrainError) -> String {
        switch error {
        case .offline:
            return String(localized: "Couldn't choose because your model isn't answering. Check that it is running and its address is right, then try again.", comment: "What to Watch on Linux when the person's model cannot be reached")
        case .busy:
            return String(localized: "Couldn't choose because your model is busy. Try again in a minute.", comment: "What to Watch on Linux when the person's model is busy")
        case .unavailable:
            return String(localized: "Set up your own model in Settings to use What to Watch.", comment: "What to Watch on Linux before a model is set up")
        case .failed, .needsPro, .allowanceUsed:
            return String(localized: "Couldn't choose because your model gave no usable answer. Check its name in Settings, then try again.", comment: "What to Watch on Linux when the person's model answered with an error or nonsense")
        case .declined:
            return WatchCopy.failure(.brain(.declined))
        }
    }

    static func failure(_ failure: WatchFailure) -> String {
        if case .brain(let error) = failure { return refusal(error) }
        return WatchCopy.failure(failure)
    }

    static let recapSends = String(localized: "Writing a recap sends the name of the series and these descriptions to your model. Nothing else leaves this computer.", comment: "Linux: what a described Previously On sends to the person's own model")
    static let recapSetup = String(localized: "Set up your own model in Settings to have these written into one recap.", comment: "Linux: hint under a Previously On made from descriptions when no model is set up")

    /// Why the person's model wrote no recap, in place of the hosted model's reasons.
    static func recapFailure(_ error: HostedBrainError) -> String {
        switch error {
        case .offline:
            return String(localized: "Couldn't write the recap because your model isn't answering. Check that it is running and its address is right, then try again.", comment: "Linux Previously On when the person's model cannot be reached")
        case .busy:
            return String(localized: "Couldn't write the recap because your model is busy. Try again in a minute.", comment: "Linux Previously On when the person's model is busy")
        case .unavailable:
            return recapSetup
        case .failed, .declined, .needsPro, .allowanceUsed:
            return String(localized: "Couldn't write the recap because your model gave no usable answer. Check its name in Settings, then try again.", comment: "Linux Previously On when the person's model answered with an error or nonsense")
        }
    }
}

/// Settings › Your Own Model (Linux only, D1): the address, the model and the key What to Watch and recaps run on, a check
/// that asks the model a small question, and Remove.
@MainActor
final class OwnModelSettingsScreen: SettingsScaffold {
    private enum RowID {
        static let address = "ownModel.address"
        static let model = "ownModel.model"
        static let key = "ownModel.key"
        static let check = "ownModel.check"
        static let remove = "ownModel.remove"
    }

    private let panel = ContextPanel(content: .init(symbol: "sparkles", title: OwnModelCopy.title, body: OwnModelCopy.explanation))
    private var isChecking = false
    /// Whether a key is saved, read from the keyring off the main thread (a locked or slow keyring must not hold up the
    /// screen); nil until the first read answers.
    private var keySaved: Bool?

    init() {
        super.init(title: OwnModelCopy.title)
        installContext(panel)
        render()
    }

    override func screenDidAppear() {
        render()
        Task { [weak self] in
            let saved = await Task.detached { OwnModel.hasKey }.value
            guard let self, self.keySaved != saved else { return }
            self.keySaved = saved
            self.render()
        }
    }

    private func render() {
        var items = [
            RowItem(id: RowID.address, title: OwnModelCopy.address, value: OwnModel.address.map(Self.shortAddress) ?? OwnModelCopy.notSet, symbol: "link", accessory: .chevron),
            RowItem(id: RowID.model, title: OwnModelCopy.model, value: OwnModel.model ?? OwnModelCopy.notSet, symbol: "sparkles", accessory: .chevron),
            RowItem(id: RowID.key, title: OwnModelCopy.key, value: keySaved.map { $0 ? OwnModelCopy.saved : OwnModelCopy.notSet } ?? "",
                    symbol: "key", accessory: .chevron),
        ]
        if OwnModel.isConfigured {
            items.append(RowItem(id: RowID.check, title: isChecking ? OwnModelCopy.checking : OwnModelCopy.check, symbol: "checkmark.circle", isEnabled: !isChecking))
            items.append(RowItem(id: RowID.remove, title: OwnModelCopy.remove, symbol: "trash", isDestructive: true))
        }
        setRows(items)
    }

    /// "192.168.1.20:8080/v1" for the row: the address without its scheme.
    private static func shortAddress(_ url: URL) -> String {
        let text = url.absoluteString
        guard let range = text.range(of: "://") else { return text }
        return String(text[range.upperBound...])
    }

    override func rowSelected(_ id: String) {
        guard let window else { return }
        switch id {
        case RowID.address:
            ask(OwnModelCopy.address, placeholder: OwnModelCopy.addressPlaceholder, text: OwnModel.address?.absoluteString ?? "") { [weak self] typed in
                guard OwnModel.setAddress(typed) else {
                    AlertView.notice(title: OwnModelCopy.badAddress, message: OwnModelCopy.addressHint, in: window)
                    return
                }
                self?.render()
            }
        case RowID.model:
            ask(OwnModelCopy.model, placeholder: OwnModelCopy.modelPlaceholder, text: OwnModel.model ?? "") { [weak self] typed in
                OwnModel.setModel(typed)
                self?.render()
            }
        case RowID.key:
            ask(OwnModelCopy.key, placeholder: OwnModelCopy.keyPlaceholder, text: "", secure: true) { [weak self] typed in
                OwnModel.setKey(typed)
                self?.keySaved = !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                self?.render()
            }
        case RowID.check:
            check()
        case RowID.remove:
            AlertView.confirm(title: OwnModelCopy.remove, message: nil, confirm: OwnModelCopy.remove, in: window) { [weak self] in
                OwnModel.remove()
                self?.keySaved = false
                self?.render()
            }
        default:
            break
        }
    }

    private func ask(_ title: String, placeholder: String, text: String, secure: Bool = false, then save: @escaping (String) -> Void) {
        guard let window else { return }
        weak var alert: AlertView?
        let shown = AlertView(title: title, actions: [
            AlertView.Action(String(localized: "Save")) { save(alert?.text ?? "") },
            AlertView.Action(String(localized: "Cancel"), role: .cancel),
        ], fieldPlaceholder: placeholder, fieldText: text, secureField: secure)
        alert = shown
        shown.present(in: window)
    }

    /// Asks the model to turn a small request into limits, which shows the address, the model and the key all work.
    private func check() {
        guard let brain = OwnModel.brain, !isChecking else { return }
        isChecking = true
        render()
        let input = "Current year: \(Calendar.current.component(.year, from: Date()))\nRequest: something funny under two hours"
        Task { [weak self] in
            let message: String
            let title: String
            do throws(HostedBrainError) {
                let reply = try await brain.ask(alias: WatchPicker.planAlias, input: input, language: HostedBrain.language)
                let parsed = reply.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                if parsed?["kind"] != nil {
                    (title, message) = (OwnModelCopy.answered, "")
                } else {
                    (title, message) = (OwnModelCopy.title, OwnModelCopy.refusal(.failed))
                }
            } catch {
                (title, message) = (OwnModelCopy.title, OwnModelCopy.refusal(error))
            }
            guard let self else { return }
            self.isChecking = false
            self.render()
            guard let window = self.window else { return }
            AlertView.notice(title: title, message: message.isEmpty ? nil : message, in: window)
        }
    }
}
