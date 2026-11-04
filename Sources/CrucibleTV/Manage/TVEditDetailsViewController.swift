import CrucibleCore
import CrucibleDesign
import UIKit

/// Edit Details on Apple TV: a title's name, sort name, original name, year (for a movie) and summary, each opened in the
/// keyboard with Select. Save sends only what changed and locks it, so the server's next metadata refresh keeps the owner's words.
final class TVEditDetailsViewController: TVSettingsScaffold {
    private enum Field: String, CaseIterable {
        case title, sortTitle, originalTitle, year, summary

        var label: String {
            switch self {
            case .title: String(localized: "Title", comment: "Edit Details field")
            case .sortTitle: String(localized: "Sort Title", comment: "Edit Details field: the name the title is sorted by")
            case .originalTitle: String(localized: "Original Title", comment: "Edit Details field")
            case .year: String(localized: "Year", comment: "Edit Details field")
            case .summary: String(localized: "Summary", comment: "Edit Details field")
            }
        }

        var symbol: String {
            switch self {
            case .title: "textformat"
            case .sortTitle: "arrow.up.arrow.down"
            case .originalTitle: "globe"
            case .year: "calendar"
            case .summary: "text.alignleft"
            }
        }
    }

    private static let saveID = "editDetails.save"

    private var edit: MetadataEdit
    private let api: APIClient
    private let onSaved: @MainActor () -> Void
    private let heading = TVSettingsHeading(
        title: String(localized: "Edit Details", comment: "Title of the Edit Details screen"),
        body: String(localized: "Saved fields are locked, so the server keeps them when it refreshes the title.", comment: "Note under the Edit Details form")
    )

    init(edit: MetadataEdit, api: APIClient, onSaved: @escaping @MainActor () -> Void) {
        self.edit = edit
        self.api = api
        self.onSaved = onSaved
        super.init()
        title = String(localized: "Edit Details", comment: "Title of the Edit Details screen")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        render()
    }

    override func rowDidSelect(_ id: String) {
        if id == Self.saveID {
            save()
        } else if let field = Field(rawValue: String(id.dropFirst("editDetails.".count))) {
            presentTextEntry(
                title: field.label,
                text: value(of: field),
                keyboard: field == .year ? .numberPad : .default,
                confirmTitle: String(localized: "Done", comment: "Button that accepts the typed text")
            ) { [weak self] text in
                self?.set(text, for: field)
                self?.render()
            }
        }
    }

    private var fields: [Field] {
        Field.allCases.filter { $0 != .year || edit.editsYear }
    }

    private func value(of field: Field) -> String {
        switch field {
        case .title: edit.title
        case .sortTitle: edit.sortTitle
        case .originalTitle: edit.originalTitle
        case .year: edit.year
        case .summary: edit.summary
        }
    }

    private func set(_ text: String, for field: Field) {
        switch field {
        case .title: edit.title = text
        case .sortTitle: edit.sortTitle = text
        case .originalTitle: edit.originalTitle = text
        case .year: edit.year = text
        case .summary: edit.summary = text
        }
    }

    private func render() {
        var rows = fields.map { field in
            TVRowItem(id: "editDetails.\(field.rawValue)", title: field.label, value: Self.shortened(value(of: field)), symbol: field.symbol)
        }
        rows.append(TVRowItem(
            id: Self.saveID,
            title: String(localized: "Save", comment: "Button that saves the Edit Details form"),
            symbol: "checkmark.circle",
            isEnabled: !edit.changedValues.isEmpty
        ))
        setRows(rows)
    }

    private static func shortened(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    private func save() {
        guard !edit.changedValues.isEmpty else { return }
        let edit = edit
        let api = api
        let onSaved = onSaved
        Task { @MainActor [weak self] in
            do {
                try await LibraryManagement.edit(edit, api: api)
                if let self { TVNavigation.pop(from: self) }
                onSaved()
            } catch {
                self?.presentAlert(title: ManageCopy.failed, message: ConnectionError.message(for: error))
            }
        }
    }
}
