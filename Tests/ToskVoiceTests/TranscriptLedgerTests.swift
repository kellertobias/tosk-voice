import XCTest
@testable import ToskVoice

final class TranscriptLedgerTests: XCTestCase {
    func testFinalSegmentsAreJoinedOnce() {
        var ledger = TranscriptLedger()
        ledger.append("Hello world.")
        ledger.append("This is ToskVoice.")
        XCTAssertEqual(ledger.text, "Hello world. This is ToskVoice.")
    }

    func testStrikeThatRemovesLastPauseBoundedUtterance() {
        var ledger = TranscriptLedger()
        ledger.append("Keep this.")
        ledger.append("Remove this.")
        XCTAssertTrue(ledger.applyStandaloneCommand("Strike that."))
        XCTAssertEqual(ledger.text, "Keep this.")
    }

    func testUndoCorrectionRestoresRemovedUtterance() {
        var ledger = TranscriptLedger()
        ledger.append("First.")
        ledger.append("Second.")
        _ = ledger.applyStandaloneCommand("Strike that")
        _ = ledger.applyStandaloneCommand("Undo correction")
        XCTAssertEqual(ledger.text, "First. Second.")
    }

    func testReplaceCommandPreservesOtherText() {
        var ledger = TranscriptLedger()
        ledger.append("Use Apos in this sentence.")
        XCTAssertTrue(ledger.applyStandaloneCommand("replace Apos with Epos"))
        XCTAssertEqual(ledger.text, "Use Epos in this sentence.")
    }

    func testLiteralProseIsNotACommand() {
        var ledger = TranscriptLedger()
        ledger.append("Existing text.")
        XCTAssertFalse(ledger.applyStandaloneCommand("I said to strike that balance carefully."))
        XCTAssertEqual(ledger.text, "Existing text.")
    }
}
