import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// The server's settings for one show on Apple TV, for its owner: Select flips an on/off setting or opens the server's
/// choices for the rest. A change is sent at once and applies to everyone who watches the show.
final class TVShowSettingsViewController: TVSettingsScaffold {
    private static let prefix = "showSettings."

    private let ratingKey: String
    private let api: APIClient
    private var settings: [ItemSetting] = []
    private let heading = TVSettingsHeading(title: ManageCopy.showSettingsTitle, body: ManageCopy.showSettingsNote)
    private lazy var loadSlot = makeTaskSlot()

    init(ratingKey: String, api: APIClient) {
        self.ratingKey = ratingKey
        self.api = api
        super.init()
        title = ManageCopy.showSettingsTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        presentState(.loading(title: nil))
        load()
    }

    override func rowDidSelect(_ id: String) {
        guard let setting = settings.first(where: { Self.prefix + $0.id == id }) else { return }
        if setting.isToggle {
            change(setting, to: setting.toggleValue(!setting.isOn))
            return
        }
        let api = api
        let key = ratingKey
        let choices = TVShowSettingChoiceViewController(setting: setting) { [weak self] picked in
            do {
                try await ItemSettings.set(setting, to: picked.value, ratingKey: key, api: api)
                let reloaded = try? await ItemSettings.load(ratingKey: key, api: api)
                if let reloaded { self?.settings = reloaded }
                self?.render()
                return reloaded?.first { $0.id == setting.id }
            } catch {
                self?.presentAlert(title: ManageCopy.failed, message: ConnectionError.message(for: error))
                return nil
            }
        }
        TVNavigation.push(choices, from: self)
    }

    override func rowDidFocus(_ id: String?) {
        let setting = settings.first { Self.prefix + $0.id == id }
        heading.setBody(setting?.summary ?? ManageCopy.showSettingsNote)
    }

    private func load() {
        loadSlot.run { [weak self] in
            guard let self else { return }
            do {
                settings = try await ItemSettings.load(ratingKey: ratingKey, api: api)
                guard !Task.isCancelled else { return }
                if settings.isEmpty {
                    presentState(.empty(title: ManageCopy.showSettingsTitle, message: ManageCopy.noShowSettings, symbol: "slider.horizontal.3", action: nil))
                } else {
                    render()
                    presentState(nil)
                }
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Show settings failed to load for \(ratingKey): \(error.localizedDescription)", category: .networking)
                presentState(.error(title: ManageCopy.failed, message: ConnectionError.message(for: error), retryTitle: String(localized: "Try Again")) { [weak self] in
                    self?.presentState(.loading(title: nil))
                    self?.load()
                })
            }
        }
    }

    private func render() {
        setRows(settings.map { setting in
            TVRowItem(id: Self.prefix + setting.id, title: setting.label, value: setting.valueTitle, symbol: setting.isToggle ? "switch.2" : "list.bullet")
        })
    }

    private func change(_ setting: ItemSetting, to value: String) {
        guard value != setting.value else { return }
        let api = api
        let key = ratingKey
        Task { @MainActor [weak self] in
            do {
                try await ItemSettings.set(setting, to: value, ratingKey: key, api: api)
                if let reloaded = try? await ItemSettings.load(ratingKey: key, api: api) { self?.settings = reloaded }
                self?.render()
            } catch {
                self?.presentAlert(title: ManageCopy.failed, message: ConnectionError.message(for: error))
            }
        }
    }
}

/// The server's choices for one show setting: a checkmark on the one in use; Select sends the pick and moves the checkmark once
/// the server took it.
final class TVShowSettingChoiceViewController: TVSettingsScaffold {
    private var setting: ItemSetting
    private let onPick: @MainActor (ItemSetting.Choice) async -> ItemSetting?

    init(setting: ItemSetting, onPick: @escaping @MainActor (ItemSetting.Choice) async -> ItemSetting?) {
        self.setting = setting
        self.onPick = onPick
        super.init()
        title = setting.label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusRowID: String? {
        Self.rowID(setting.value)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(TVSettingsHeading(title: setting.label, body: setting.summary ?? ManageCopy.showSettingsNote))
        render()
    }

    override func rowDidSelect(_ id: String) {
        guard let choice = setting.choices.first(where: { Self.rowID($0.value) == id }), choice.value != setting.value else { return }
        Task { @MainActor [weak self] in
            guard let self, let updated = await onPick(choice) else { return }
            setting = updated
            render()
        }
    }

    private func render() {
        setRows(setting.choices.map { choice in
            TVRowItem(id: Self.rowID(choice.value), title: choice.title, accessory: choice.value == setting.value ? .checkmark : .none)
        })
    }

    private static func rowID(_ value: String) -> String {
        "showSettings.choice.\(value)"
    }
}
