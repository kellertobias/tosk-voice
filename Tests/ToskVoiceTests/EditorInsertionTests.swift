import Foundation
@testable import ToskVoice
import XCTest

final class EditorInsertionTests: XCTestCase {
    func testAppendAfterWordGetsLeadingSpace() {
        XCTAssertEqual(
            EditorInsertion.padded("world", in: "hello", replacing: NSRange(location: 5, length: 0)),
            " world"
        )
    }

    func testAppendAfterSpaceNeedsNoLeadingSpace() {
        XCTAssertEqual(
            EditorInsertion.padded("world", in: "hello ", replacing: NSRange(location: 6, length: 0)),
            "world"
        )
    }

    func testInsertionBeforeWordGetsTrailingSpace() {
        XCTAssertEqual(
            EditorInsertion.padded("brave", in: "one world", replacing: NSRange(location: 4, length: 0)),
            "brave "
        )
    }

    func testInsertionBetweenWordsGetsBothSpaces() {
        XCTAssertEqual(
            EditorInsertion.padded("X", in: "one.two", replacing: NSRange(location: 4, length: 0)),
            " X "
        )
        XCTAssertEqual(
            EditorInsertion.padded("X", in: "onetwo", replacing: NSRange(location: 3, length: 0)),
            " X "
        )
    }

    func testNoTrailingSpaceBeforeClosingPunctuation() {
        XCTAssertEqual(
            EditorInsertion.padded("X", in: "one.", replacing: NSRange(location: 3, length: 0)),
            " X"
        )
    }

    func testReplacingSelectionChecksNeighborsOutsideSelection() {
        // Replacing "two" in "one two three" — spaces already on both sides.
        XCTAssertEqual(
            EditorInsertion.padded("2", in: "one two three", replacing: NSRange(location: 4, length: 3)),
            "2"
        )
    }

    func testEmptyDocument() {
        XCTAssertEqual(
            EditorInsertion.padded("hello", in: "", replacing: NSRange(location: 0, length: 0)),
            "hello"
        )
    }

    func testEmptyTextStaysEmpty() {
        XCTAssertEqual(
            EditorInsertion.padded("", in: "abc", replacing: NSRange(location: 1, length: 0)),
            ""
        )
    }

    func testNoLeadingSpaceAfterNewline() {
        XCTAssertEqual(
            EditorInsertion.padded("word", in: "line\n", replacing: NSRange(location: 5, length: 0)),
            "word"
        )
    }
}

final class SpokenReplacementTests: XCTestCase {
    func testParsesEnglishReplaceCommand() {
        let parsed = SpokenReplacement.parse("Replace deadline with due date.")
        XCTAssertEqual(parsed?.target, "deadline")
        XCTAssertEqual(parsed?.replacement, "due date")
    }

    func testParsesGermanReplaceCommand() {
        let parsed = SpokenReplacement.parse("Ersetze Montag durch Dienstag")
        XCTAssertEqual(parsed?.target, "Montag")
        XCTAssertEqual(parsed?.replacement, "Dienstag")
    }

    func testProseIsNotAReplaceCommand() {
        XCTAssertNil(SpokenReplacement.parse("We should replace the old process at some point with care"))
        // No "with"/"durch" clause at all:
        XCTAssertNil(SpokenReplacement.parse("Please update the deadline"))
    }

    func testAppliesLiterallyCaseInsensitive() {
        XCTAssertEqual(
            SpokenReplacement.apply(to: "The Deadline is Friday.", utterance: "replace deadline with due date"),
            "The due date is Friday."
        )
    }

    func testApplyReturnsNilWhenTargetMissing() {
        XCTAssertNil(SpokenReplacement.apply(to: "Nothing to see.", utterance: "replace deadline with due date"))
    }
}
