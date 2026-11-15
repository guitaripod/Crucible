import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// How the desk draws Crucible, kept between launches: light or dark, Desk or Couch density, and the poster size (which
/// `CardZoom` keeps). `--light` and `--couch` on the command line win over what is saved, for that launch only.
@MainActor
enum LinuxDisplay {
    private static let appearanceKey = "linux.appearance"
    private static let densityKey = "linux.density"

    /// Puts the saved appearance, density and poster size on the theme at launch.
    static func restore(arguments: [String]) {
        let theme = Theme.current
        let defaults = UserDefaults.standard
        let savedCouch = defaults.string(forKey: densityKey) == "couch"
        let savedLight = defaults.string(forKey: appearanceKey) == "light"
        theme.density = arguments.contains("--couch") || savedCouch ? .couch : .desk
        theme.palette = arguments.contains("--light") || savedLight ? .light : .dark
        theme.cardZoom = CardZoom.saved
    }

    static var isLight: Bool { Theme.current.palette.appearance == .light }
    static var isCouch: Bool { Theme.current.density == .couch }

    static var appearanceLabel: String { isLight ? String(localized: "Light") : String(localized: "Dark") }
    static var densityLabel: String { isCouch ? String(localized: "Couch") : String(localized: "Desk") }
    static var posterSizeLabel: String { "\(Int((Theme.current.cardZoom * 100).rounded()))%" }

    /// "Dark · Desk · 100%", the Appearance category's value line.
    static var summary: String { [appearanceLabel, densityLabel, posterSizeLabel].joined(separator: " · ") }

    /// Switches between light and dark everywhere at once, and keeps the choice.
    static func toggleAppearance(in window: Window?) {
        let theme = Theme.current
        theme.palette = isLight ? .dark : .light
        UserDefaults.standard.set(isLight ? "light" : "dark", forKey: appearanceKey)
        window?.background = theme.palette.canvas
        window?.relayoutEverything()
    }

    /// Switches between Desk and Couch density everywhere at once, and keeps the choice.
    static func toggleDensity(in window: Window?) {
        let theme = Theme.current
        theme.density = isCouch ? .desk : .couch
        UserDefaults.standard.set(isCouch ? "couch" : "desk", forKey: densityKey)
        window?.relayoutEverything()
    }
}

/// Settings › Appearance on Linux (the iPhone's Appearance category, with what a desk adds): light or dark, Desk or Couch
/// density, and the poster size that Ctrl with plus, minus or the wheel also changes.
@MainActor
final class AppearanceSettingsScreen: SettingsScaffold {
    private enum RowID {
        static let appearance = "appearance.palette"
        static let density = "appearance.density"
        static let posterSize = "appearance.posterSize"
    }

    private static let posterSizes: [Float] = stride(from: 0.7, through: 1.6, by: 0.1).map { ($0 * 10).rounded() / 10 }

    init() {
        super.init(title: SettingsCategory.appearance.title(on: .linux), detail: SettingsCategory.appearance.explanation(on: .linux))
        render()
    }

    override func screenDidAppear() {
        render()
    }

    private func render() {
        setRows([
            RowItem(id: RowID.appearance, title: String(localized: "Appearance"), value: LinuxDisplay.appearanceLabel, symbol: "circle.lefthalf.filled"),
            RowItem(id: RowID.density, title: String(localized: "Interface Size"),
                    subtitle: String(localized: "Desk draws the Apple TV design for a monitor; Couch draws it as on a TV across the room."),
                    value: LinuxDisplay.densityLabel, symbol: "textformat.size"),
            RowItem(id: RowID.posterSize, title: String(localized: "Poster Size"), value: LinuxDisplay.posterSizeLabel, symbol: "square.grid.2x2",
                    accessory: .chevron),
        ])
    }

    override func rowSelected(_ id: String) {
        switch id {
        case RowID.appearance: LinuxDisplay.toggleAppearance(in: window)
        case RowID.density: LinuxDisplay.toggleDensity(in: window)
        case RowID.posterSize: choosePosterSize()
        default: break
        }
        render()
    }

    /// The sizes from 70% to 160% in a menu, the current one checked.
    private func choosePosterSize() {
        guard let window, let anchor = rows.row(id: RowID.posterSize)?.frameInWindow else { return }
        let current = (Theme.current.cardZoom * 10).rounded() / 10
        let items = Self.posterSizes.map { size in
            MenuView.Item(id: String(size), title: "\(Int((size * 100).rounded()))%", isChecked: abs(size - current) < 0.01)
        }
        let menu = MenuView(title: String(localized: "Poster Size"), items: items,
                            anchor: Rect(x: anchor.maxX - Theme.current.metrics.tv(500), y: anchor.maxY, width: 1, height: 1))
        menu.onSelect = { [weak self] chosen in
            guard let size = Float(chosen.id) else { return }
            CardZoom.set(size)
            self?.window?.relayoutEverything()
            self?.render()
        }
        menu.present(in: window)
    }
}
