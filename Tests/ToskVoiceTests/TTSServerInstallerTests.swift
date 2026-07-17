import XCTest
@testable import ToskVoice

final class TTSServerInstallerTests: XCTestCase {
    func testFishSpeechUsesTorchCompatiblePython() {
        let script = TTSServerPreset.fishSpeech.installScript

        XCTAssertTrue(script.contains("uv python install 3.13"))
        XCTAssertTrue(script.contains("uv sync --python 3.13"))
    }
}
