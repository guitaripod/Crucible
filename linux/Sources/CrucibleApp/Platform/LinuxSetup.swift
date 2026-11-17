import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Everything Core needs from Linux before the first read: the Secret Service for tokens, pinned HTTPS for Crucible Server,
/// GDM for servers on the local network, the string catalog the Apple apps compile, and the design system's own strings
/// looked up in it.
@MainActor
enum LinuxSetup {
    static func install() {
        CrucibleLog.configure()
        let fallback = FileSecretStore(url: AppPlatform.persistentDirectory.appendingPathComponent("secrets.json"))
        KeychainHelper.install(SecretServiceStore(fallback: fallback))
        CompanionTransport.install(CurlPinnedTransport())
        LocalServerFinder.install()
        loadStrings()
        Strings.lookup = { key in String(localized: String.LocalizationValue(stringLiteral: key)) }
        AppInfo.override = (CrucibleLinux.version, CrucibleLinux.build)
    }

    /// Reads `Localizable.xcstrings` for the desktop's languages (`LANGUAGE`, then `LANG`), English otherwise, and then
    /// `Web.xcstrings`, web video's strings, which live in a catalog of the Linux client's own so the Apple apps, which
    /// have no web video, never carry them.
    private static func loadStrings() {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url) else {
            MidgarLog.error("The string catalog is missing; showing English keys", category: .lifecycle)
            return
        }
        do {
            try LocalizationCatalog.shared.load(xcstrings: data, preferredLanguages: preferredLanguages())
            if let web = Bundle.module.url(forResource: "Web", withExtension: "xcstrings") {
                try LocalizationCatalog.shared.add(xcstrings: Data(contentsOf: web))
            }
        } catch {
            MidgarLog.error("The string catalog did not load: \(error)", category: .lifecycle)
        }
    }

    /// The desktop's language order: `LANGUAGE` (colon separated, as GNU gettext reads it), then `LC_ALL`, `LC_MESSAGES`
    /// and `LANG`, with encodings and modifiers stripped (`fi_FI.UTF-8` becomes `fi-FI`).
    static func preferredLanguages(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var languages: [String] = []
        if let list = environment["LANGUAGE"], !list.isEmpty {
            languages += list.split(separator: ":").map(String.init)
        }
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let value = environment[key], !value.isEmpty { languages.append(value) }
        }
        let cleaned = languages.compactMap { raw -> String? in
            let base = raw.split(separator: ".").first.map(String.init) ?? raw
            let bare = base.split(separator: "@").first.map(String.init) ?? base
            guard bare != "C", bare != "POSIX", !bare.isEmpty else { return nil }
            return bare.replacingOccurrences(of: "_", with: "-")
        }
        return cleaned.isEmpty ? ["en"] : cleaned
    }
}

/// Opens links in the desktop's browser.
enum Browser {
    /// `CRUCIBLE_NO_BROWSER=1` (headless tests) logs the link instead of opening it.
    static func open(_ url: URL) {
        if ProcessInfo.processInfo.environment["CRUCIBLE_NO_BROWSER"] == "1" {
            MidgarLog.notice("Would open \(url.host ?? "a link") in the browser", category: .lifecycle)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            MidgarLog.error("xdg-open failed: \(error)", category: .lifecycle)
        }
    }
}
