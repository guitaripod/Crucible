import Foundation
import Testing
@testable import CrucibleCore

struct LibraryAlphabetIndexTests {
    private func index(_ json: String) throws -> LibraryAlphabetIndex {
        let response = try JSONDecoder().decode(LibraryFirstCharacterResponse.self, from: Data(json.utf8))
        return LibraryAlphabetIndex(entries: response.MediaContainer.Directory ?? [])
    }

    private let sample = #"""
    {"MediaContainer":{"Directory":[
      {"key":"#","title":"#","size":5},
      {"key":"a","title":"A","size":10},
      {"key":"c","title":"C","size":20},
      {"key":"d","title":"D","size":0},
      {"key":"m","title":"M","size":7}
    ]}}
    """#

    @Test func lettersRunAToZThenHash() {
        #expect(LibraryAlphabetIndex.letters.count == 27)
        #expect(LibraryAlphabetIndex.letters.first == "A")
        #expect(LibraryAlphabetIndex.letters[25] == "Z")
        #expect(LibraryAlphabetIndex.letters.last == "#")
    }

    @Test func offsetsAccumulateInServerOrder() throws {
        let index = try index(sample)
        #expect(index.offset(for: "#") == 0)
        #expect(index.offset(for: "A") == 5)
        #expect(index.offset(for: "C") == 15)
        #expect(index.offset(for: "M") == 35)
    }

    @Test func missingLettersFallForwardToTheNextOneWithItems() throws {
        let index = try index(sample)
        #expect(index.offset(for: "B") == 15)
        #expect(index.offset(for: "D") == 35)
        #expect(index.offset(for: "L") == 35)
    }

    @Test func lettersPastTheLastFallBackToTheLastLetterWithItems() throws {
        let index = try index(sample)
        #expect(index.offset(for: "Z") == 35)
        #expect(index.offset(for: "N") == 35)
    }

    @Test func unknownLettersHaveNoOffset() throws {
        let index = try index(sample)
        #expect(index.offset(for: "1") == nil)
        #expect(index.offset(for: "") == nil)
    }

    @Test func offsetsMapBackToTheirLetter() throws {
        let index = try index(sample)
        #expect(index.letter(atOffset: 0) == "#")
        #expect(index.letter(atOffset: 4) == "#")
        #expect(index.letter(atOffset: 5) == "A")
        #expect(index.letter(atOffset: 14) == "A")
        #expect(index.letter(atOffset: 15) == "C")
        #expect(index.letter(atOffset: 500) == "M")
    }

    @Test func accentedAndLowercaseKeysFoldOntoTheirBaseLetter() throws {
        let index = try index(#"{"MediaContainer":{"Directory":[{"key":"É","size":3},{"title":"z","size":2},{"key":"7","size":4}]}}"#)
        #expect(index.offset(for: "E") == 0)
        #expect(index.offset(for: "Z") == 3)
        #expect(index.offset(for: "#") == 5)
    }

    @Test func entriesWithoutAKeyOrTitleCountAsHash() throws {
        let index = try index(#"{"MediaContainer":{"Directory":[{"size":2},{"key":"b","size":3}]}}"#)
        #expect(index.offset(for: "#") == 0)
        #expect(index.offset(for: "B") == 2)
    }

    @Test func repeatedLettersKeepTheirFirstOffset() throws {
        let index = try index(#"{"MediaContainer":{"Directory":[{"key":"a","size":2},{"key":"a","size":2},{"key":"b","size":1}]}}"#)
        #expect(index.offset(for: "A") == 0)
        #expect(index.offset(for: "B") == 4)
    }

    @Test func theIndexIsUsableFromTwoLettersUp() throws {
        #expect(try index(sample).isUsable)
        #expect(try !index(#"{"MediaContainer":{"Directory":[{"key":"a","size":9}]}}"#).isUsable)
        #expect(try !index(#"{"MediaContainer":{}}"#).isUsable)
        #expect(!LibraryAlphabetIndex(entries: []).isUsable)
        #expect(LibraryAlphabetIndex(entries: []).letter(atOffset: 3) == nil)
    }

    @Test func availableLettersFollowTheAlphabetWithHashLast() throws {
        #expect(try index(sample).availableLetters == ["A", "C", "M", "#"])
    }

    @Test func fractionsSpreadTheAlphabetOverTheStrip() {
        #expect(LibraryAlphabetIndex.letter(atFraction: 0) == "A")
        #expect(LibraryAlphabetIndex.letter(atFraction: -3) == "A")
        #expect(LibraryAlphabetIndex.letter(atFraction: 0.5) == "N")
        #expect(LibraryAlphabetIndex.letter(atFraction: 1) == "#")
        #expect(LibraryAlphabetIndex.letter(atFraction: 7) == "#")
    }

    @Test func steppingStopsAtBothEnds() {
        #expect(LibraryAlphabetIndex.letter(from: "A", offsetBy: 1) == "B")
        #expect(LibraryAlphabetIndex.letter(from: "Z", offsetBy: 1) == "#")
        #expect(LibraryAlphabetIndex.letter(from: "#", offsetBy: 1) == "#")
        #expect(LibraryAlphabetIndex.letter(from: "A", offsetBy: -1) == "A")
        #expect(LibraryAlphabetIndex.letter(from: "C", offsetBy: -1) == "B")
    }

    @Test func steppingWithoutACurrentLetterLandsOnTheFirstLetter() {
        #expect(LibraryAlphabetIndex.letter(from: nil, offsetBy: 1) == "A")
        #expect(LibraryAlphabetIndex.letter(from: nil, offsetBy: -1) == "A")
        #expect(LibraryAlphabetIndex.letter(from: "?", offsetBy: 1) == "A")
    }
}
