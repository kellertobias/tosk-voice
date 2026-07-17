import AppKit
@testable import ToskVoice
import XCTest

@MainActor
final class DictationEditorBridgeTests: XCTestCase {
    private var textView: NSTextView!
    private var bridge: DictationEditorTextBridge!

    override func setUp() async throws {
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.allowsUndo = true
        bridge = DictationEditorTextBridge()
        bridge.textView = textView
    }

    private func setDocument(_ text: String, caret: Int? = nil) {
        bridge.replaceDocument(with: text)
        if let caret { textView.setSelectedRange(NSRange(location: caret, length: 0)) }
    }

    func testVolatileThenFinalAppendsAtEnd() {
        setDocument("Hello world.")
        bridge.showVolatile("this is")
        bridge.showVolatile("this is new")
        XCTAssertEqual(bridge.documentText, "Hello world.")
        XCTAssertEqual(textView.string, "Hello world. this is new")
        bridge.clearVolatile()
        bridge.insertFinal("This is new.")
        XCTAssertEqual(textView.string, "Hello world. This is new.")
        XCTAssertEqual(bridge.documentText, textView.string)
    }

    func testDictationContinuesAtClickedCaret() {
        setDocument("One two three", caret: 3)
        bridge.showVolatile("and")
        XCTAssertEqual(textView.string, "One and two three")
        bridge.clearVolatile()
        bridge.insertFinal("plus")
        XCTAssertEqual(textView.string, "One plus two three")
    }

    func testSpeakingOverSelectionReplacesIt() {
        setDocument("Keep REPLACE keep")
        textView.setSelectedRange(NSRange(location: 5, length: 7))
        bridge.showVolatile("better")
        XCTAssertEqual(textView.string, "Keep better keep")
        bridge.clearVolatile()
        bridge.insertFinal("much better")
        XCTAssertEqual(textView.string, "Keep much better keep")
    }

    func testFinalWithoutVolatileInsertsAtSelection() {
        setDocument("Start end", caret: 5)
        bridge.insertFinal("middle")
        XCTAssertEqual(textView.string, "Start middle end")
    }

    func testDocumentTextExcludesVolatile() {
        setDocument("Stable.")
        bridge.showVolatile("maybe")
        XCTAssertEqual(bridge.documentText, "Stable.")
        bridge.clearVolatile()
        XCTAssertEqual(textView.string, "Stable.")
    }

    func testVolatileSurvivesKeyboardEditBeforeIt() {
        setDocument("abc def")
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        bridge.showVolatile("ghi")
        // Simulate a keyboard edit at the front, shifting all ranges.
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        bridge.showVolatile("ghi jkl")
        XCTAssertEqual(textView.string, "Xabc def ghi jkl")
        bridge.clearVolatile()
        bridge.insertFinal("ghi jkl.")
        XCTAssertEqual(textView.string, "Xabc def ghi jkl.")
    }

    func testAppendParagraphSeparatesWithBlankLine() {
        setDocument("")
        bridge.appendParagraph("First")
        bridge.appendParagraph("Second")
        XCTAssertEqual(textView.string, "First\n\nSecond")
    }

    func testDiscardAnchorLeavesNextFinalAtCaret() {
        setDocument("A B", caret: 1)
        bridge.showVolatile("replace A with C")
        bridge.clearVolatile()
        bridge.discardAnchor()
        XCTAssertEqual(textView.string, "A B")
    }
}
