import AppKit
@testable import ToskVoice
import XCTest

@MainActor
final class MenuControllerTests: XCTestCase {
    func testActiveMeterImageUsesAdaptiveTemplateRendering() {
        let image = MenuController.meterImage(
            levels: [0.1, 0.4, 0.8, 0.2],
            accessibilityDescription: "Listening"
        )

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "Listening")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }
}
