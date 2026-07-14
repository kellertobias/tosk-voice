import Foundation
import FoundationModels
import Security

private struct ProviderConfiguration: Codable {
    var kind: String
    var baseURL: String
    var model: String
}

private struct PreferenceSnapshot: Codable {
    var provider: ProviderConfiguration
}

private struct FileChange: Codable {
    var path: String
    var original: String?
    var replacement: String?
    var rationale: String?
}

private struct EditPlan: Codable {
    var summary: String
    var changes: [FileChange]
}

@main
@MainActor
private struct ToskVoiceACPAgent {
    private static var sessions: [String: URL] = [:]
    private static let supportedExtensions = Set(["swift", "md", "txt", "json", "yaml", "yml", "toml", "js", "jsx", "ts", "tsx", "css", "html", "py", "rs", "go", "java", "kt", "c", "h", "cpp", "hpp", "sh", "zsh", "rb"])

    static func main() async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else { continue }
            let id = request["id"]
            let params = request["params"] as? [String: Any] ?? [:]
            do {
                switch method {
                case "initialize":
                    respond(id: id, result: [
                        "protocolVersion": 1,
                        "agentInfo": ["name": "ToskVoice", "version": "0.1.0"],
                        "agentCapabilities": [
                            "loadSession": false,
                            "promptCapabilities": ["audio": false, "image": false, "embeddedContext": false],
                            "mcpCapabilities": ["http": false, "sse": false],
                            "sessionCapabilities": [:],
                        ],
                        "authMethods": [],
                    ])
                case "session/new":
                    guard let cwd = params["cwd"] as? String else { throw ACPError.invalid("session/new requires cwd") }
                    let sessionID = UUID().uuidString
                    sessions[sessionID] = URL(fileURLWithPath: cwd, isDirectory: true)
                    respond(id: id, result: [
                        "sessionId": sessionID,
                        "modes": [
                            "currentModeId": "edit",
                            "availableModes": [["id": "edit", "name": "File-only editor", "description": "Reads and edits text files without shell access"]],
                        ],
                    ])
                case "session/set_mode":
                    respond(id: id, result: [:])
                case "session/prompt":
                    try await prompt(id: id, params: params)
                case "session/cancel":
                    break
                default:
                    respondError(id: id, code: -32601, message: "Method not found")
                }
            } catch {
                respondError(id: id, code: -32603, message: error.localizedDescription)
            }
        }
    }

    private static func prompt(id: Any?, params: [String: Any]) async throws {
        guard let sessionID = params["sessionId"] as? String, let root = sessions[sessionID] else {
            throw ACPError.invalid("Unknown session")
        }
        let blocks = params["prompt"] as? [[String: Any]] ?? []
        let instruction = blocks.compactMap { block -> String? in
            if block["type"] as? String == "text" { return block["text"] as? String }
            if block["type"] as? String == "resource_link" { return block["uri"] as? String }
            return nil
        }.joined(separator: "\n")
        guard !instruction.isEmpty else { throw ACPError.invalid("A text prompt is required") }

        notify(sessionID: sessionID, update: [
            "sessionUpdate": "agent_thought_chunk",
            "content": ["type": "text", "text": "Reading text files inside the Zed project root…"],
        ])
        let context = try workspaceContext(root: root)
        let plan = try await makePlan(instruction: instruction, context: context)
        var applied = 0
        for change in plan.changes {
            let url = try safeURL(path: change.path, root: root)
            let currentData = try? Data(contentsOf: url)
            let current = currentData.flatMap { String(data: $0, encoding: .utf8) }
            guard current == change.original else { throw ACPError.invalid("\(change.path) changed while the edit was being prepared") }
            if let replacement = change.replacement {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(replacement.utf8).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let toolCallID = UUID().uuidString
            notify(sessionID: sessionID, update: [
                "sessionUpdate": "tool_call",
                "toolCallId": toolCallID,
                "title": "Edit \(change.path)",
                "kind": change.replacement == nil ? "delete" : "edit",
                "status": "completed",
                "locations": [["path": url.path]],
                "content": [[
                    "type": "diff",
                    "path": url.path,
                    "oldText": change.original as Any,
                    "newText": change.replacement ?? "",
                ]],
            ])
            applied += 1
        }
        let message = applied == 0 ? plan.summary : "\(plan.summary)\n\nApplied \(applied) file change\(applied == 1 ? "" : "s"). Review them in Zed before committing."
        notify(sessionID: sessionID, update: [
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": message],
        ])
        respond(id: id, result: ["stopReason": "end_turn"])
    }

    private static func workspaceContext(root: URL) throws -> String {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return "" }
        var result: [String] = []
        var count = 0
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative.hasPrefix(".git/") || relative.hasPrefix(".build/") || relative.hasPrefix("node_modules/") {
                enumerator.skipDescendants()
                continue
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) || url.lastPathComponent == "Makefile" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 80_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let section = "<<<FILE \(relative)>>>\n\(text)\n<<<END FILE>>>"
            guard count + section.count < 180_000 else { break }
            result.append(section)
            count += section.count
        }
        return result.joined(separator: "\n\n")
    }

    private static func makePlan(instruction: String, context: String) async throws -> EditPlan {
        let system = """
        You are the file-only ToskVoice editor inside Zed. Return JSON only:
        {"summary":"short explanation","changes":[{"path":"relative/path","original":"complete existing contents or null","replacement":"complete desired contents or null to delete","rationale":"reason"}]}
        Paths must be relative, stay inside the project, and never contain '..'. Preserve unrelated content.
        """
        let prompt = "WORKSPACE:\n\(context)\n\nREQUEST:\n\(instruction)"
        let configuration = providerConfiguration()
        let response: String
        if configuration.kind == "apple" {
            guard case .available = SystemLanguageModel.default.availability else {
                throw ACPError.invalid("Apple Intelligence is unavailable. Configure an OpenAI-compatible provider in ToskVoice.")
            }
            response = try await LanguageModelSession(instructions: system).respond(to: prompt).content
        } else {
            response = try await openAI(configuration: configuration, system: system, prompt: prompt)
        }
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        json = json.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
        json = json.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        guard let data = json.data(using: .utf8), let plan = try? JSONDecoder().decode(EditPlan.self, from: data) else {
            throw ACPError.invalid("The model returned an invalid edit plan")
        }
        return plan
    }

    private static func providerConfiguration() -> ProviderConfiguration {
        let environment = ProcessInfo.processInfo.environment
        if let model = environment["TOSKVOICE_MODEL"] {
            return ProviderConfiguration(kind: "openAICompatible", baseURL: environment["TOSKVOICE_BASE_URL"] ?? "http://localhost:11434/v1", model: model)
        }
        let defaults = UserDefaults(suiteName: "de.tobisk.toskvoice")
        if let data = defaults?.data(forKey: "ToskVoice.AgentPreferences.v1"),
           let snapshot = try? JSONDecoder().decode(PreferenceSnapshot.self, from: data) { return snapshot.provider }
        return ProviderConfiguration(kind: "apple", baseURL: "", model: "")
    }

    private static func openAI(configuration: ProviderConfiguration, system: String, prompt: String) async throws -> String {
        let base = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !configuration.model.isEmpty, let url = URL(string: base + "/chat/completions") else { throw ACPError.invalid("Provider model or URL is missing") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = ProcessInfo.processInfo.environment["TOSKVOICE_API_KEY"] ?? keychainAPIKey()
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "temperature": 0.1,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ACPError.invalid("The configured provider rejected the request")
        }
        return content
    }

    private static func keychainAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "de.tobisk.toskvoice.provider",
            kSecAttrAccount as String: "openai-compatible",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func safeURL(path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ACPError.invalid("Unsafe path: \(path)") }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(path).standardizedFileURL
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == canonicalRoot.path || parent.path.hasPrefix(canonicalRoot.path + "/") else { throw ACPError.invalid("Unsafe path: \(path)") }
        return target
    }

    private static func notify(sessionID: String, update: [String: Any]) {
        write(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": sessionID, "update": update]])
    }

    private static func respond(id: Any?, result: [String: Any]) {
        guard let id else { return }
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func respondError(id: Any?, code: Int, message: String) {
        guard let id else { return }
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object), var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

private enum ACPError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
