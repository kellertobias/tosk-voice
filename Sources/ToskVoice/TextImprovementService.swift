import Foundation
import FoundationModels

enum TextImprovementError: LocalizedError {
    case appleIntelligenceUnavailable
    case notConfigured
    case badResponse(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .appleIntelligenceUnavailable:
            "Apple Intelligence is unavailable on this Mac — configure an external server in Settings → General."
        case .notConfigured:
            "The external server is not configured — set its URL and model in Settings → General."
        case .badResponse(let detail):
            "The server request failed: \(detail)"
        case .emptyResult:
            "The model returned no text."
        }
    }
}

/// Cleans dictated text of verbal artifacts for the Edit with Voice window's
/// "Improve Result" button, using either the on-device Apple Intelligence
/// model or an external OpenAI-compatible chat endpoint (Ollama, mlx, OpenAI).
enum TextImprovementService {
    static let instructions = """
    You clean up dictated text. Remove filler words and verbal artifacts such as \
    "uh", "um", "er", "ehm", "äh", "ähm", and "hmm", stutters, duplicated words, \
    false starts, and abandoned sentence fragments. Repair punctuation and \
    capitalization where a removal requires it. Keep the author's language, \
    wording, meaning, tone, paragraph breaks, and formatting. Do not summarize, \
    shorten beyond the removals, or add content. Return only the cleaned text \
    with no preface, labels, quotation marks, or commentary.
    """

    static func improve(_ text: String, configuration: TextImprovementConfiguration) async throws -> String {
        switch configuration.provider {
        case .appleIntelligence:
            return try await improveOnDevice(text)
        case .openAICompatible:
            return try await improveViaServer(text, configuration: configuration)
        }
    }

    private static func improveOnDevice(_ text: String) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw TextImprovementError.appleIntelligenceUnavailable
        }
        let session = LanguageModelSession(instructions: instructions)
        let response: String
        do {
            response = try await session.respond(to: "Clean this dictated text:\n\n\(text)").content
        } catch {
            throw TextImprovementError.badResponse(error.localizedDescription)
        }
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TextImprovementError.emptyResult }
        return cleaned
    }

    private static func improveViaServer(_ text: String, configuration: TextImprovementConfiguration) async throws -> String {
        guard configuration.isUsable, let endpoint = configuration.chatCompletionsEndpoint else {
            throw TextImprovementError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = configuration.apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body = ChatRequest(
            model: configuration.model.trimmingCharacters(in: .whitespaces),
            messages: [
                .init(role: "system", content: instructions),
                .init(role: "user", content: "Clean this dictated text:\n\n\(text)"),
            ],
            temperature: 0.2,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TextImprovementError.badResponse(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw TextImprovementError.badResponse("HTTP \(http.statusCode) \(detail)")
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw TextImprovementError.badResponse("unexpected response format")
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TextImprovementError.emptyResult }
        return cleaned
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }
}
