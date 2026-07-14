import SpeakerKit
@testable import ToskVoice
import XCTest

final class SpeakerAlignmentTests: XCTestCase {
    func testUsesSpeakerWithGreatestTimeOverlapAndOneBasedLabel() {
        let utterances = [
            TimedUtterance(text: "Hello", start: 0, end: 2),
            TimedUtterance(text: "Hi", start: 2, end: 4),
        ]
        let speakers = [
            SpeakerSegment(speaker: .speakerId(0), startTime: 0, endTime: 2.2, frameRate: 100),
            SpeakerSegment(speaker: .speakerId(1), startTime: 1.8, endTime: 4, frameRate: 100),
        ]

        XCTAssertEqual(SpeakerAlignment.labels(for: utterances, speakerSegments: speakers), ["Speaker 1", "Speaker 2"])
    }

    func testLeavesUtteranceUnlabeledWithoutOverlap() {
        let utterances = [TimedUtterance(text: "Silence", start: 4, end: 5)]
        let speakers = [SpeakerSegment(speaker: .speakerId(0), startTime: 0, endTime: 1, frameRate: 100)]

        XCTAssertEqual(SpeakerAlignment.labels(for: utterances, speakerSegments: speakers), [nil])
    }
}
