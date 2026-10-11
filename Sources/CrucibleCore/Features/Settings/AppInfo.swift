import Foundation

/// Version, licence and credits shown by the About screens and the diagnostics report.
package enum AppInfo {
    package struct Acknowledgement: Equatable, Sendable {
        package let name: String
        package let license: String
        package let url: URL
    }

    package static let sourceURL = URL(string: "https://github.com/guitaripod/Crucible")
    package static let licenseName = "GPL-3.0"
    package static let licenseSummary = "Crucible is free software, released under the GNU General Public License v3.0. You can read, change and share the source."

    package static let acknowledgements = [
        Acknowledgement(name: "GRDB.swift", license: "MIT", url: URL(string: "https://github.com/groue/GRDB.swift")!),
    ]

    package static var versionText: String { versionText(from: Bundle.main.infoDictionary) }

    package static var buildText: String { buildText(from: Bundle.main.infoDictionary) }

    /// "2.0.1 (7)", the form the You tab and the Settings footer print.
    package static var versionSummary: String { "\(versionText) (\(buildText))" }

    static func versionText(from info: [String: Any]?) -> String {
        info?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static func buildText(from info: [String: Any]?) -> String {
        info?["CFBundleVersion"] as? String ?? "1"
    }
}
