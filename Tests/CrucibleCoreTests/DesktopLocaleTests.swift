@testable import CrucibleCore
import Foundation
import Testing

struct DesktopLocaleTests {
    @Test func theInterfaceLanguageTakesTheDesktopsRegion() {
        #expect(DesktopLocale.identifier(language: "fi", environment: ["LANG": "en_GB.UTF-8"]) == "fi_GB")
        #expect(DesktopLocale.identifier(language: "en", environment: ["LANG": "fi_FI.UTF-8"]) == "en_FI")
    }

    @Test func dateVariablesWinOverLang() {
        #expect(DesktopLocale.region(in: ["LANG": "en_US.UTF-8", "LC_TIME": "de_DE.UTF-8"]) == "DE")
        #expect(DesktopLocale.region(in: ["LANG": "en_US.UTF-8", "LC_TIME": "sv_SE", "LC_ALL": "fr_FR@euro"]) == "FR")
    }

    @Test func aLanguageThatNamesItsRegionKeepsIt() {
        #expect(DesktopLocale.identifier(language: "pt-BR", environment: ["LANG": "en_GB.UTF-8"]) == "pt_BR")
        #expect(DesktopLocale.identifier(language: "zh-Hans", environment: ["LANG": "zh_TW.UTF-8"]) == "zh_Hans_TW")
    }

    @Test func aPlainDesktopAddsNoRegion() {
        #expect(DesktopLocale.identifier(language: "de", environment: ["LANG": "C.UTF-8"]) == "de")
        #expect(DesktopLocale.identifier(language: "de", environment: ["LC_ALL": "POSIX"]) == "de")
        #expect(DesktopLocale.identifier(language: "ja", environment: [:]) == "ja")
    }
}
