import CrucibleCore
import CrucibleDesign
import UIKit

/// About: the app's identity on the left, version, build, licence, source and the open-source
/// credits on the right.
final class TVAboutViewController: TVSettingsScaffold {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "About Crucible"
        buildContextColumn()
        setRows(rows())
    }

    private func buildContextColumn() {
        let glyph = CrystalGlyphView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.isAccessibilityElement = false

        let nameLabel = UILabel()
        nameLabel.text = "Crucible"
        nameLabel.font = Theme.Font.title1
        nameLabel.textColor = Theme.Color.label
        nameLabel.accessibilityTraits = .header

        let versionLabel = UILabel()
        versionLabel.text = "Version \(AppInfo.versionSummary)"
        versionLabel.font = Theme.Font.callout
        versionLabel.textColor = Theme.Color.labelSecondary

        let licenseLabel = UILabel()
        licenseLabel.text = AppInfo.licenseSummary
        licenseLabel.font = Theme.Font.body
        licenseLabel.textColor = Theme.Color.labelSecondary
        licenseLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [glyph, nameLabel, versionLabel, licenseLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.xs
        stack.setCustomSpacing(Theme.Space.l, after: versionLabel)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 220),
            glyph.heightAnchor.constraint(equalToConstant: 220),
        ])
        let panel = TVReadOnlyPanel(wrapping: stack) {
            "Crucible. Version \(AppInfo.versionSummary). \(AppInfo.licenseSummary)"
        }
        panel.accessibilityIdentifier = "about.context"
        installContext(panel)
    }

    private func rows() -> [TVRowItem] {
        var rows = [
            TVRowItem(id: "about.version", title: "Version", value: AppInfo.versionText, symbol: "info.circle"),
            TVRowItem(id: "about.build", title: "Build", value: AppInfo.buildText, symbol: "hammer"),
            TVRowItem(id: "about.license", title: "License", value: AppInfo.licenseName, symbol: "doc.text"),
        ]
        if let source = AppInfo.sourceURL {
            rows.append(TVRowItem(
                id: "about.source",
                title: "Source Code",
                subtitle: (source.host ?? "") + source.path,
                symbol: "chevron.left.forwardslash.chevron.right"
            ))
        }
        for credit in AppInfo.acknowledgements {
            rows.append(TVRowItem(
                id: "about.credit.\(credit.name)",
                title: credit.name,
                subtitle: (credit.url.host ?? "") + credit.url.path,
                value: credit.license,
                symbol: "shippingbox"
            ))
        }
        return rows
    }
}
