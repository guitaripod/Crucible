import Foundation

/// The locale a Linux desktop asks for, which Foundation's `Locale.current` does not follow there: the language the
/// interface runs in, with the region of `LC_ALL`, `LC_TIME` or `LANG`, so a Finnish interface on a British desktop writes
/// "15. marraskuuta" with British conventions, and an English one in Finland writes English months with a Finnish week.
package enum DesktopLocale {
    /// The variables that carry the region, most specific first, as glibc reads them for dates.
    private static let regionVariables = ["LC_ALL", "LC_TIME", "LANG"]

    /// The locale identifier for `language` (a catalog language such as "fi", "pt-BR" or "zh-Hans") on a desktop whose
    /// locale variables are `environment`. A language that names its region keeps it; a "C" or "POSIX" desktop adds none.
    package static func identifier(language: String, environment: [String: String]) -> String {
        let parts = language.replacingOccurrences(of: "-", with: "_").split(separator: "_").map(String.init)
        let named = parts.dropFirst().contains { $0.count == 2 && $0 == $0.uppercased() }
        guard !named, let region = region(in: environment) else { return parts.joined(separator: "_") }
        return (parts + [region]).joined(separator: "_")
    }

    /// The two-letter region of the first locale variable that names one: "fi_FI.UTF-8" gives "FI", "en_GB@euro" gives "GB".
    package static func region(in environment: [String: String]) -> String? {
        for name in regionVariables {
            guard let raw = environment[name], !raw.isEmpty, raw != "C", raw != "POSIX", !raw.hasPrefix("C.") else { continue }
            let base = raw.split(separator: ".").first.map(String.init) ?? raw
            let trimmed = base.split(separator: "@").first.map(String.init) ?? base
            let pieces = trimmed.split(separator: "_")
            guard pieces.count >= 2, let region = pieces.last, region.count == 2 else { continue }
            return region.uppercased()
        }
        return nil
    }
}
