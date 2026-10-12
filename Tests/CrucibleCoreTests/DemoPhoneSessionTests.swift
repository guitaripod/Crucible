import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct DemoPhoneSessionTests {
    private func session() -> DemoPhoneSession {
        DemoPhoneSession(defaults: UserDefaults(suiteName: "demo-phone-\(UUID().uuidString)")!)
    }

    @Test func theIntroIsOwedOnceFromTheStartOfASession() {
        let session = session()
        #expect(!session.introIsPending)
        session.beginSession()
        #expect(session.introIsPending)
        session.introWasShown()
        #expect(!session.introIsPending)
    }

    @Test func aNewSessionOwesTheIntroAgain() {
        let session = session()
        session.beginSession()
        session.introWasShown()
        session.endSession()
        session.beginSession()
        #expect(session.introIsPending)
    }

    @Test func endingASessionClearsAnIntroNeverShown() {
        let session = session()
        session.beginSession()
        session.endSession()
        #expect(!session.introIsPending)
    }
}

struct DemoPhoneSearchSampleTests {
    @Test func itTakesTheFirstWordLongEnoughToSearch() {
        #expect(DemoPhoneSearchSample.query(fromTitles: ["A Tale of Halcyon"]) == "Tale")
        #expect(DemoPhoneSearchSample.query(fromTitles: ["Halcyon Days"]) == "Halcyon")
    }

    @Test func itSkipsTitlesWithNothingToSearchFor() {
        #expect(DemoPhoneSearchSample.query(fromTitles: ["12", "Up", "Ember Line"]) == "Ember")
    }

    @Test func itStripsPunctuationFromTheWord() {
        #expect(DemoPhoneSearchSample.query(fromTitles: ["Salt-Flat: Origins"]) == "Salt")
    }

    @Test func itReturnsNothingWhenNoTitleQualifies() {
        #expect(DemoPhoneSearchSample.query(fromTitles: []) == nil)
        #expect(DemoPhoneSearchSample.query(fromTitles: ["Up", "It"]) == nil)
    }
}
