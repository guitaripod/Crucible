import Foundation
import Testing
@testable import CrucibleCore

struct TraktCommentMarkupTests {
    private let samples = [
        "Loved it. **The acting** is *great* and ~~boring~~ never dull.",
        "Watch `code` here and [the trailer](https://example.com/trailer) or https://trakt.tv/movies/x for more.",
        "First line\n> quoted line from someone\nlast line",
        "Open [spoiler]the father dies[/spoiler] and then more.",
        "Spoiler across [spoiler]two\nlines here[/spoiler] done.",
        "Line\n\nAfter a blank line :joy:",
        "> only a quote",
        "Trailing break\n",
        "snake_case and 5 * 3 stay as written",
    ]

    @Test func markupReadsBackIntoTheSameText() {
        for raw in samples {
            let text = TraktCommentText(raw)
            let rebuilt = TraktCommentText(TraktCommentText.markup(text.lines))
            #expect(rebuilt == text, "\(raw)")
        }
    }

    @Test func linesKeepQuotesBreaksAndSpoilers() {
        let lines = TraktCommentText("Hi **there**\n> quoted [spoiler]secret[/spoiler]\nend").lines
        #expect(lines.count == 3)
        #expect(lines[0].runs.map(\.text) == ["Hi ", "there"])
        #expect(lines[0].runs[1].styles == [.bold])
        #expect(lines[0].endsWithBreak)
        #expect(lines[1].isQuote)
        #expect(lines[1].runs.last?.isSpoiler == true)
        #expect(lines[1].runs.allSatisfy { !$0.styles.contains(.quote) })
        #expect(!lines[2].endsWithBreak)
    }

    @Test func translatedRunsBecomeMarkupWithTheirStyles() {
        let lines = [
            TraktCommentText.Line(runs: [
                .init(text: "Me encantó. "),
                .init(text: "El padre muere", styles: [.bold], isSpoiler: true),
                .init(text: " al final."),
            ], endsWithBreak: true),
            TraktCommentText.Line(runs: [.init(text: "Una cita")], isQuote: true),
        ]
        #expect(TraktCommentText.markup(lines) == "Me encantó. [spoiler]**El padre muere**[/spoiler] al final.\n> Una cita")
    }

    @Test func aLineWithOnlyCodeOrLinksHasNoWordsToTranslate() {
        #expect(!TraktCommentText("`npm i`").lines[0].hasWords)
        #expect(!TraktCommentText("https://trakt.tv").lines[0].hasWords)
        #expect(TraktCommentText("Great film").lines[0].hasWords)
        #expect(!TraktCommentText("10/10 !!!").lines[0].hasWords)
    }
}

@Suite(.serialized) struct TranslationLanguageTests {
    @Test func regionsMatchButScriptsDoNot() {
        #expect(TranslationLanguages.isSame("pt-BR", "pt"))
        #expect(TranslationLanguages.isSame("en-GB", "en"))
        #expect(TranslationLanguages.isSame("zh", "zh-Hans"))
        #expect(TranslationLanguages.isSame("zh-TW", "zh-Hant"))
        #expect(!TranslationLanguages.isSame("zh-Hans", "zh-Hant"))
        #expect(TranslationLanguages.isSame("no", "nb"))
        #expect(!TranslationLanguages.isSame("sv", "nb"))
    }

    @Test func supportedLanguagesAreKeptInCatalogOrder() {
        defer { TranslationLanguages.setSupported([]) }
        TranslationLanguages.setSupported(["zh-TW", "en-US", "fi", "xx", "es-419"])
        #expect(TranslationLanguages.available == ["en", "es", "fi", "zh-Hant"])
        #expect(TranslationLanguages.isAvailable)
    }

    @Test func automaticFollowsTheFirstPreferredLanguageTheDeviceOffers() {
        let available = ["de", "en", "fi", "pt", "zh-Hans"]
        #expect(TranslationPreferences.automaticLanguage(available: available, preferred: ["fi", "en"]) == "fi")
        #expect(TranslationPreferences.automaticLanguage(available: available, preferred: ["is", "pt-BR"]) == "pt")
        #expect(TranslationPreferences.automaticLanguage(available: available, preferred: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(TranslationPreferences.automaticLanguage(available: available, preferred: ["is"]) == "en")
        #expect(TranslationPreferences.automaticLanguage(available: ["fr"], preferred: ["is"]) == "fr")
    }

    @Test func settingsOfferTranslationOnlyWhereTheDeviceTranslates() {
        defer { TranslationLanguages.setSupported([]) }
        TranslationLanguages.setSupported([])
        #expect(!SettingsCatalog.categories(on: .phone).contains(.translation))
        TranslationLanguages.setSupported(["en", "fi"])
        #expect(SettingsCatalog.categories(on: .phone).contains(.translation))
        #expect(SettingsCatalog.categories(on: .tv).contains(.translation))
        #expect(!SettingsCatalog.categories(on: .linux).contains(.translation))
        let rows = SettingsCatalog.preferences(in: .translation, on: .phone)
        #expect(rows == [.translateAutomatically, .translationLanguage])
    }

    @Test @MainActor func choosingALanguageStoresItAndAutomaticForgetsIt() {
        defer {
            TranslationLanguages.setSupported([])
            TranslationPreferences.chosenLanguage = nil
        }
        TranslationLanguages.setSupported(["en", "fi", "ja"])
        let japanese = PreferenceSetting.translationLanguage.choices.first { $0.title == TranslationLanguages.name("ja") }
        #expect(japanese != nil)
        if let japanese { PreferenceSetting.translationLanguage.select(japanese) }
        #expect(TranslationPreferences.chosenLanguage == "ja")
        #expect(TranslationPreferences.targetLanguage == "ja")
        #expect(PreferenceSetting.translationLanguage.isChanged)
        PreferenceSetting.translationLanguage.restoreDefault()
        #expect(TranslationPreferences.chosenLanguage == nil)
        #expect(PreferenceSetting.translationLanguage.choices.first?.isSelected == true)
    }
}
