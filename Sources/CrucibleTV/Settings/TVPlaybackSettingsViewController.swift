import CrucibleCore
import CrucibleDesign
import UIKit

/// Playback: streaming quality and skip intro open a single-select list, autoplay flips in place.
final class TVPlaybackSettingsViewController: TVSettingsScaffold {
    private static let intro = "How Crucible plays what you pick from your server."

    private let heading = TVSettingsHeadingView(title: "Playback", body: TVPlaybackSettingsViewController.intro)

    private static let symbols: [PreferenceSetting: String] = [
        .streamingQuality: "dial.high",
        .skipIntro: "forward.end",
        .autoplayNextEpisode: "play",
    ]

    private static let settings: [PreferenceSetting] = [.streamingQuality, .skipIntro, .autoplayNextEpisode]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Playback"
        installContext(heading)
        refreshRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshRows()
    }

    override func rowDidSelect(_ id: String) {
        guard let setting = Self.settings.first(where: { Self.rowID($0) == id }) else { return }
        switch setting.control {
        case .choice:
            navigationController?.pushViewController(TVSettingsChoiceViewController(setting: setting), animated: true)
        case .toggle(let isOn):
            setting.setOn(!isOn)
            refreshRows()
        }
    }

    override func rowDidFocus(_ id: String?) {
        let setting = Self.settings.first { Self.rowID($0) == id }
        heading.setBody(setting?.explanation ?? Self.intro)
    }

    private func refreshRows() {
        setRows(Self.settings.map { setting in
            TVRowItem(
                id: Self.rowID(setting),
                title: setting.title,
                value: setting.valueLabel,
                symbol: Self.symbols[setting],
                accessory: setting.choices.isEmpty ? .none : .chevron
            )
        })
    }

    static func rowID(_ setting: PreferenceSetting) -> String {
        "playback.\(setting)"
    }
}

/// The single-select list a choice setting opens: one row per choice with a checkmark on the
/// current one. Selecting applies it immediately; Back returns.
final class TVSettingsChoiceViewController: TVSettingsScaffold {
    private let setting: PreferenceSetting

    init(setting: PreferenceSetting) {
        self.setting = setting
        super.init(nibName: nil, bundle: nil)
        title = setting.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusRowID: String? {
        setting.choices.first(where: \.isSelected).map(Self.rowID)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let heading = TVSettingsHeadingView(title: setting.title, body: setting.explanation)
        installContext(heading)
        refreshRows()
    }

    override func rowDidSelect(_ id: String) {
        guard let choice = setting.choices.first(where: { Self.rowID($0) == id }) else { return }
        setting.select(choice)
        refreshRows()
    }

    private func refreshRows() {
        setRows(setting.choices.map { choice in
            TVRowItem(id: Self.rowID(choice), title: choice.title, accessory: choice.isSelected ? .checkmark : .none)
        })
    }

    private static func rowID(_ choice: SettingChoice) -> String {
        "choice.\(choice.id)"
    }
}
