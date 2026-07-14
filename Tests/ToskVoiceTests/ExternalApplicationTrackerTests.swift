@testable import ToskVoice
import XCTest

final class ExternalApplicationTrackerTests: XCTestCase {
    func testUsesFrontmostExternalApplication() {
        XCTAssertEqual(
            ExternalApplicationTracker.preferredTarget(
                frontmost: 42,
                current: 10,
                lastExternal: 30
            ),
            42
        )
    }

    func testFallsBackToLastExternalApplicationWhenToskVoiceIsFrontmost() {
        XCTAssertEqual(
            ExternalApplicationTracker.preferredTarget(
                frontmost: 10,
                current: 10,
                lastExternal: 42
            ),
            42
        )
    }
}
