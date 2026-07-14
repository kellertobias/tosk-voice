import Foundation
import FoundationModels

actor FoundationCorrectionService {
    func shouldAttemptSemanticCorrection(_ utterance: String) -> Bool {
        let value = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("no, ") || value.hasPrefix("actually") || value.hasPrefix("change ") ||
            value.hasPrefix("nein, ") || value.hasPrefix("eigentlich") || value.hasPrefix("ändere ")
    }

    func revise(transcript: String, command: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
        You edit a staged speech transcript. Apply only the user's correction. Preserve all unrelated wording.
        Return only the complete revised transcript. If the request is ambiguous, return exactly AMBIGUOUS.
        """)
        let prompt = """
        TRANSCRIPT:
        \(transcript)

        SPOKEN CORRECTION:
        \(command)
        """
        do {
            let response = try await session.respond(to: prompt)
            let revised = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !revised.isEmpty, revised != "AMBIGUOUS" else { return nil }
            return revised
        } catch {
            return nil
        }
    }
}
