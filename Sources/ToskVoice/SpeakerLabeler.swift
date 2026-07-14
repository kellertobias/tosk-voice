import Foundation
@preconcurrency import SpeakerKit

enum SpeakerAlignment {
    static func labels(for utterances: [TimedUtterance], speakerSegments: [SpeakerSegment]) -> [String?] {
        utterances.map { utterance in
            let best = speakerSegments.compactMap { segment -> (Int, Float)? in
                guard let id = segment.speaker.speakerId else { return nil }
                let overlap = max(0, min(utterance.end, segment.endTime) - max(utterance.start, segment.startTime))
                return overlap > 0 ? (id, overlap) : nil
            }.max { $0.1 < $1.1 }
            return best.map { "Speaker \($0.0 + 1)" }
        }
    }
}

actor SpeakerLabeler {
    func labels(audio: [Float], utterances: [TimedUtterance], using kit: SpeakerKit) async throws -> [String?] {
        guard !audio.isEmpty, !utterances.isEmpty else { return Array(repeating: nil, count: utterances.count) }
        let result = try await kit.diarize(audioArray: audio)
        return SpeakerAlignment.labels(for: utterances, speakerSegments: result.segments)
    }
}
