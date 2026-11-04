import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Edit Details: a title's name, sort name, original name, year (for a movie) and summary. Saving sends only what changed
/// and locks it, so the server's next metadata refresh keeps the owner's words.
final class EditDetailsViewController: UIViewController {
    private var edit: MetadataEdit
    private let api: APIClient
    private let onSaved: @MainActor () -> Void
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let titleField = UITextField()
    private let sortField = UITextField()
    private let originalField = UITextField()
    private let yearField = UITextField()
    private let summaryView = UITextView()

    init(edit: MetadataEdit, api: APIClient, onSaved: @escaping @MainActor () -> Void) {
        self.edit = edit
        self.api = api
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Edit Details", comment: "Title of the Edit Details screen")
        view.backgroundColor = Theme.Color.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })
        stack.axis = .vertical
        stack.spacing = Theme.Space.l
        addField(String(localized: "Title", comment: "Edit Details field"), titleField, edit.title)
        addField(String(localized: "Sort Title", comment: "Edit Details field: the name the title is sorted by"), sortField, edit.sortTitle)
        addField(String(localized: "Original Title", comment: "Edit Details field"), originalField, edit.originalTitle)
        if edit.editsYear {
            addField(String(localized: "Year", comment: "Edit Details field"), yearField, edit.year)
            yearField.keyboardType = .numberPad
        }
        addSummary()
        let footnote = UILabel()
        footnote.text = String(localized: "Saved fields are locked, so the server keeps them when it refreshes the title.", comment: "Note under the Edit Details form")
        footnote.font = Theme.Font.caption1Regular
        footnote.textColor = Theme.Color.labelSecondary
        footnote.numberOfLines = 0
        stack.addArrangedSubview(footnote)
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.l),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.l),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.l),
        ])
    }

    private func addField(_ label: String, _ field: UITextField, _ value: String) {
        field.text = value
        field.borderStyle = .roundedRect
        field.font = Theme.Font.body
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = label
        stack.addArrangedSubview(caption(label))
        stack.addArrangedSubview(field)
        stack.setCustomSpacing(Theme.Space.xs, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    private func addSummary() {
        let label = String(localized: "Summary", comment: "Edit Details field")
        summaryView.text = edit.summary
        summaryView.font = Theme.Font.body
        summaryView.backgroundColor = Theme.Color.surfaceRaised
        summaryView.layer.cornerRadius = 8
        summaryView.isScrollEnabled = false
        summaryView.accessibilityLabel = label
        summaryView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        stack.addArrangedSubview(caption(label))
        stack.addArrangedSubview(summaryView)
        stack.setCustomSpacing(Theme.Space.xs, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.footnoteSemibold
        label.textColor = Theme.Color.labelSecondary
        return label
    }

    private func save() {
        view.endEditing(true)
        edit.title = titleField.text ?? edit.title
        edit.sortTitle = sortField.text ?? ""
        edit.originalTitle = originalField.text ?? ""
        if edit.editsYear { edit.year = yearField.text ?? "" }
        edit.summary = summaryView.text ?? ""
        guard !edit.changedValues.isEmpty else {
            dismiss(animated: true)
            return
        }
        let edit = edit
        let api = api
        let onSaved = onSaved
        navigationItem.rightBarButtonItem?.isEnabled = false
        ManageMenus.run(host: self) { [weak self] in
            defer { self?.navigationItem.rightBarButtonItem?.isEnabled = true }
            try await LibraryManagement.edit(edit, api: api)
            self?.dismiss(animated: true)
            onSaved()
        }
    }
}
