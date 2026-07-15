@testable import ToskVoice
import XCTest

@MainActor
final class SettingsRelaunchStateTests: XCTestCase {
    func testConsumesPrivacyTabOnlyOnceAfterRestart() throws {
        let suiteName = "SettingsRelaunchStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsRelaunchState.prepare(selectedTab: .privacy, defaults: defaults)

        XCTAssertEqual(SettingsRelaunchState.consumeSelectedTab(defaults: defaults), .privacy)
        XCTAssertNil(SettingsRelaunchState.consumeSelectedTab(defaults: defaults))
    }
}
