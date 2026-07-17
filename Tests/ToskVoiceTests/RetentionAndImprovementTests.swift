import Foundation
@testable import ToskVoice
import XCTest

final class HistoryRetentionTests: XCTestCase {
    func testDefaultIsTwentyFourHours() {
        XCTAssertEqual(HistoryRetention.hours24.maxAge, 24 * 3_600)
    }

    func testOffDisablesPruning() {
        XCTAssertNil(HistoryRetention.off.maxAge)
    }

    func testAllCasesHaveDistinctLabels() {
        let labels = HistoryRetention.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    @MainActor
    func testPruneRemovesOnlyExpiredEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToskVoiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        store.add(HistoryEntry(text: "fresh", profileName: "Test", destinationDescription: "t"))
        store.configureRetention { 3_600 }
        store.prune(now: Date())
        XCTAssertEqual(store.entries.count, 1, "fresh entries must survive")
        store.prune(now: Date().addingTimeInterval(2 * 3_600))
        XCTAssertTrue(store.entries.isEmpty, "expired entries must be removed")
    }
}

final class TextImprovementConfigurationTests: XCTestCase {
    func testEndpointFromBareHost() {
        var config = TextImprovementConfiguration()
        config.baseURL = "localhost:11434"
        XCTAssertEqual(config.chatCompletionsEndpoint?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testEndpointFromV1Base() {
        var config = TextImprovementConfiguration()
        config.baseURL = "https://api.openai.com/v1"
        XCTAssertEqual(config.chatCompletionsEndpoint?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testEndpointFromFullPath() {
        var config = TextImprovementConfiguration()
        config.baseURL = "http://box:8080/v1/chat/completions/"
        XCTAssertEqual(config.chatCompletionsEndpoint?.absoluteString, "http://box:8080/v1/chat/completions")
    }

    func testAppleProviderIsAlwaysUsable() {
        XCTAssertTrue(TextImprovementConfiguration().isUsable)
    }

    func testExternalProviderNeedsURLAndModel() {
        var config = TextImprovementConfiguration()
        config.provider = .openAICompatible
        XCTAssertFalse(config.isUsable)
        config.baseURL = "localhost:11434"
        XCTAssertFalse(config.isUsable)
        config.model = "llama3.1"
        XCTAssertTrue(config.isUsable)
    }
}
