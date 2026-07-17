import AppKit
@testable import ToskVoice
import XCTest

@MainActor
final class DictationEditorWindowTests: XCTestCase {
    /// Builds the real window (NSHostingController + representable) and
    /// verifies the SwiftUI text area wires its bridge to the controller and
    /// that a transcript seeded before the view exists lands in the document.
    func testShowBuildsTextBridgeAndAppliesSeededTranscript() {
        let windowController = DictationEditorWindowController(preferences: PreferencesStore(), modelPacks: ModelPackController())
        windowController.controller.seedExpandedTranscript("Handed-over transcript")
        windowController.show()

        let deadline = Date().addingTimeInterval(3)
        while windowController.controller.bridge == nil || !windowController.controller.hasContent,
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertNotNil(windowController.controller.bridge, "text view bridge was never wired")
        XCTAssertEqual(windowController.controller.bridge?.documentText, "Handed-over transcript")
        XCTAssertTrue(windowController.controller.isDirty)
        XCTAssertTrue(windowController.controller.hasContent)
    }
}
