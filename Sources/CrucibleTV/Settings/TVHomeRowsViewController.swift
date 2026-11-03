import CrucibleCore
import CrucibleDesign
import UIKit

/// Home's rows on Apple TV in the order Home draws them: Select turns a row on or off, and a long press moves it up or down.
final class TVHomeRowsViewController: TVSettingsScaffold {
    private static let resetID = "homeRows.reset"

    private let heading = TVSettingsHeading(
        title: SettingsCatalog.title(.homeRows),
        body: SettingsCatalog.explanation(.homeRows)
    )

    override init() {
        super.init()
        title = SettingsCatalog.title(.homeRows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        refreshRows()
    }

    override func rowDidSelect(_ id: String) {
        if id == Self.resetID {
            HomeLayout.reset()
        } else if let row = Self.row(for: id) {
            HomeLayout.setOn(row, !HomeLayout.isOn(row))
        }
        refreshRows()
    }

    override func rowDidFocus(_ id: String?) {
        heading.setBody(Self.row(for: id ?? "")?.explanation ?? SettingsCatalog.explanation(.homeRows))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = rowID(at: indexPath), let row = Self.row(for: id),
              let index = HomeLayout.entries().firstIndex(where: { $0.row == row }) else { return nil }
        let count = HomeLayout.entries().count
        var actions = [UIAction]()
        if index > 0 {
            actions.append(UIAction(title: String(localized: "Move Up", comment: "Menu item that moves a Home row up"), image: UIImage(systemName: "arrow.up")) { [weak self] _ in
                HomeLayout.move(from: index, to: index - 1)
                self?.refreshRows()
            })
        }
        if index < count - 1 {
            actions.append(UIAction(title: String(localized: "Move Down", comment: "Menu item that moves a Home row down"), image: UIImage(systemName: "arrow.down")) { [weak self] _ in
                HomeLayout.move(from: index, to: index + 1)
                self?.refreshRows()
            })
        }
        return TVContextMenu.configuration(menu: UIMenu(children: actions))
    }

    private func refreshRows() {
        let rows = HomeLayout.entries().map { entry in
            TVRowItem(
                id: Self.rowID(entry.row),
                title: entry.row.title,
                value: entry.isOn ? String(localized: "On") : String(localized: "Off"),
                symbol: entry.row.symbol
            )
        }
        setRows(rows + [TVRowItem(id: Self.resetID, title: String(localized: "Reset Order", comment: "Row that puts Home's rows back in their default order and turns them all on"), symbol: "arrow.counterclockwise")])
    }

    private static func rowID(_ row: HomeRow) -> String {
        "homeRows.\(row.rawValue)"
    }

    private static func row(for id: String) -> HomeRow? {
        HomeRow.allCases.first { rowID($0) == id }
    }
}
