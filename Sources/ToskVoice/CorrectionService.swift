import Foundation
import FoundationModels

actor FoundationCorrectionService {
    private var editingSession: LanguageModelSession?
    private var polishingSession: LanguageModelSession?

    func beginDictation(enableEditing: Bool, enablePolishing: Bool) {
        editingSession = nil
        polishingSession = nil
        guard case .available = SystemLanguageModel.default.availability else { return }
        if enableEditing {
            let session = makeEditingSession()
            session.prewarm()
            editingSession = session
        }
        if enablePolishing {
            let session = makePolishingSession()
            session.prewarm()
            polishingSession = session
        }
    }

    func endDictation() {
        editingSession = nil
        polishingSession = nil
    }

    func integrate(transcript: String, utterance: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = editingSession ?? makeEditingSession()
        editingSession = session
        let prompt = """
        STAGED TEXT:
        \(transcript)

        NEW SPOKEN UTTERANCE:
        \(utterance)
        """
        do {
            let response = try await session.respond(to: prompt)
            return CorrectionModelOutput.clean(response.content)
        } catch {
            return nil
        }
    }

    func condense(_ transcript: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = polishingSession ?? makePolishingSession()
        polishingSession = session
        do {
            let response = try await session.respond(to: "Polish this dictation:\n\n\(transcript)")
            return CorrectionModelOutput.clean(response.content)
        } catch {
            return nil
        }
    }

    private func makeEditingSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
        You are a live dictation editor. For each new spoken utterance, return the complete updated staged text.
        Decide from natural language whether the utterance is ordinary dictation or an instruction that edits existing text.
        For ordinary dictation, append it faithfully. For an edit instruction, execute it and omit the instruction itself.
        Instructions can use unrestricted natural language; they are not limited to a command list.
        The utterance may mix new prose and corrections. Keep every new phrase that survives the requested edit.
        Resolve references such as “that,” “the last sentence,” or “the second paragraph” from the staged text.
        Preserve all unrelated wording. Do not summarize or polish unless explicitly asked in the utterance.
        Return only the complete updated text. Never include labels, analysis, STAGED TEXT, or NEW SPOKEN UTTERANCE.
        If the intended result truly cannot be determined, return exactly AMBIGUOUS.
        """)
    }

    private func makePolishingSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
        You polish a completed voice dictation. Produce a concise, coherent final version that preserves the user's meaning.
        Apply corrections, remove superseded wording, false starts, correction commands, and accidental repetition.
        Preserve useful paragraph breaks and speaker labels. Do not add facts or commentary.
        Return only the polished text with no heading, label, preface, quotation marks, or analysis.
        """)
    }
}

enum CorrectionTrigger {
    static func shouldAskModelToEdit(_ utterance: String) -> Bool {
        let value = utterance
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "no,", "no ", "oh no", "no wait", "wait, no", "actually", "change ",
            "let me rephrase", "i mean", "sorry,", "correction:",
            "nein,", "nein ", "oh nein", "warte, nein", "eigentlich", "ändere ",
            "anders gesagt", "ich meine", "korrektur:",
        ]
        if prefixes.contains(where: value.hasPrefix) { return true }

        let commandPattern = #"(?i)\b(strike that|delete that|scratch that|streich das|lösche das)\b(?:\s*[,.;!?]|\s*$)"#
        guard let expression = try? NSRegularExpression(pattern: commandPattern) else { return false }
        let range = NSRange(location: 0, length: (utterance as NSString).length)
        return expression.firstMatch(in: utterance, range: range) != nil
    }
}

enum LiveDraftRouting {
    static func shouldUseModel(hasStagedText: Bool, utterance: String) -> Bool {
        hasStagedText || CorrectionTrigger.shouldAskModelToEdit(utterance)
    }
}

enum CorrectionModelOutput {
    static func clean(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned.caseInsensitiveCompare("AMBIGUOUS") != .orderedSame,
              !cleaned.localizedCaseInsensitiveContains("SPOKEN CORRECTION:"),
              !cleaned.localizedCaseInsensitiveContains("TRANSCRIPT:"),
              !cleaned.localizedCaseInsensitiveContains("NEW SPOKEN UTTERANCE:"),
              !cleaned.localizedCaseInsensitiveContains("STAGED TEXT:") else { return nil }
        return cleaned
    }
}
