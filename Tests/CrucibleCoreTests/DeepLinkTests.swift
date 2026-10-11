import Foundation
import Testing
@testable import CrucibleCore

@Suite
struct DeepLinkTests {
    private func parse(_ string: String) -> DeepLink? {
        URL(string: string).flatMap(DeepLink.init(url:))
    }

    @Test func itemLinkCarriesRatingKeyAndType() {
        #expect(parse("crucible://item/4009?type=movie") == .item(ratingKey: "4009", mediaType: "movie"))
        #expect(parse("crucible://item/1002?type=show") == .item(ratingKey: "1002", mediaType: "show"))
        #expect(parse("crucible://item/4010?type=episode") == .item(ratingKey: "4010", mediaType: "episode"))
    }

    @Test func itemLinkWithoutTypeLeavesItToBeResolved() {
        #expect(parse("crucible://item/4009") == .item(ratingKey: "4009", mediaType: nil))
    }

    @Test func itemLinkWithUnknownTypeIsRejected() {
        #expect(parse("crucible://item/4009?type=artist") == nil)
    }

    @Test func playLinkCarriesRatingKey() {
        #expect(parse("crucible://play/4009") == .play(ratingKey: "4009"))
    }

    @Test func schemeAndHostAreCaseInsensitive() {
        #expect(parse("CRUCIBLE://Play/4009") == .play(ratingKey: "4009"))
    }

    @Test func otherSchemesAndHostsAreRejected() {
        #expect(parse("https://item/4009?type=movie") == nil)
        #expect(parse("crucible://settings/4009") == nil)
        #expect(parse("crucible://item") == nil)
    }

    @Test func nonNumericOrEmptyRatingKeysAreRejected() {
        #expect(parse("crucible://play/") == nil)
        #expect(parse("crucible://play/abc") == nil)
        #expect(parse("crucible://play/12%2F34") == nil)
        #expect(parse("crucible://play/12/34") == nil)
        #expect(parse("crucible://item/-5?type=movie") == nil)
    }
}
