import Foundation
@testable import ToskVoice
import XCTest

final class ListeningPlaceholderTests: XCTestCase {
    func testMatchesExpectedUTF16Range() {
        let prefix = "Hello 🙂 "
        let value = prefix + ListeningPlaceholder.text + " world"
        let range = CFRange(
            location: (prefix as NSString).length,
            length: (ListeningPlaceholder.text as NSString).length
        )

        XCTAssertTrue(ListeningPlaceholder.matches(in: value, range: range))
    }

    func testRejectsChangedOrInvalidPlaceholderRange() {
        XCTAssertFalse(ListeningPlaceholder.matches(
            in: "[Recording]",
            range: CFRange(location: 0, length: 11)
        ))
        XCTAssertFalse(ListeningPlaceholder.matches(
            in: "short",
            range: CFRange(location: 10, length: 11)
        ))
    }
}
