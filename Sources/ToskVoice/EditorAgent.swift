import AppKit
import AVFoundation
import CryptoKit
import Foundation
import FoundationModels
import Security

enum AgentProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case openAICompatible

    var id: String { rawValue }
    var label: String { self == .apple ? "Apple Intelligence" : "OpenAI-compatible API" }
}

enum AgentApprovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case preview
    case autoApply

    var id: String { rawValue }
    var label: String { self == .preview ? "Review every change" : "Apply automatically" }
}

struct AgentProviderConfiguration: Codable, Equatable, Sendable {
    var kind: AgentProviderKind = .apple
    var baseURL = "http://localhost:11434/v1"
    var model = ""
    var speakResponses = false
}

struct AgentWorkspace: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var displayPath: String
    var bookmark: Data
    var approvalMode: AgentApprovalMode = .preview
}

@MainActor
final class AgentPreferencesStore: ObservableObject {
    @Published var provider: AgentProviderConfiguration { didSet { save() } }
    @Published var workspaces: [AgentWorkspace] { didSet { save() } }
    @Published var selectedWorkspaceID: UUID? { didSet { save() } }

    private struct Snapshot: Codable {
        var provider: AgentProviderConfiguration
        var workspaces: [AgentWorkspace]
        var selectedWorkspaceID: UUID?
    }

    private let defaults = UserDefaults.standard
    private let key = "ToskVoice.AgentPreferences.v1"

    init() {
        if let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Snapshot.self, from: data) {
            provider = value.provider
            workspaces = value.workspaces
            selectedWorkspaceID = value.selectedWorkspaceID
        } else {
            provider = AgentProviderConfiguration()
            workspaces = []
            selectedWorkspaceID = nil
        }
    }

    var selectedWorkspace: AgentWorkspace? {
        get { workspaces.first { $0.id == selectedWorkspaceID } }
        set {
            guard let newValue else { selectedWorkspaceID = nil; return }
            if let index = workspaces.firstIndex(where: { $0.id == newValue.id }) { workspaces[index] = newValue }
            selectedWorkspaceID = newValue.id
        }
    }

    func addWorkspace(url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil)
        let workspace = AgentWorkspace(name: url.lastPathComponent, displayPath: url.path, bookmark: bookmark)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
    }

    func removeSelectedWorkspace() {
        workspaces.removeAll { $0.id == selectedWorkspaceID }
        selectedWorkspaceID = workspaces.first?.id
    }

    func setApprovalMode(_ mode: AgentApprovalMode) {
        guard let id = selectedWorkspaceID, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].approvalMode = mode
    }

    private func save() {
        let value = Snapshot(provider: provider, workspaces: workspaces, selectedWorkspaceID: selectedWorkspaceID)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

enum KeychainCredentialStore {
    private static let service = "de.tobisk.toskvoice.provider"

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "openai-compatible",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func saveAPIKey(_ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "openai-compatible",
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AgentError.provider("Keychain error \(status)") }
    }
}

struct ProposedFileChange: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var original: String?
    var replacement: String?
    var rationale: String?
}

struct AgentEditPlan: Codable, Equatable, Sendable {
    var summary: String
    var changes: [ProposedFileChange]
}

struct ValidatedFileChange: Identifiable, Equatable, Sendable {
    var id: String { relativePath }
    var relativePath: String
    var original: String?
    var replacement: String?
    var rationale: String?
    var originalDigest: String?

    var diff: String {
        let before = original ?? ""
        let after = replacement ?? ""
        var lines = ["--- a/\(relativePath)", "+++ b/\(relativePath)"]
        if original == nil { lines.append("@@ new file @@") }
        else if replacement == nil { lines.append("@@ deleted file @@") }
        else { lines.append("@@ replacement @@") }
        lines.append(contentsOf: before.split(separator: "\n", omittingEmptySubsequences: false).map { "-\($0)" })
        lines.append(contentsOf: after.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" })
        return lines.joined(separator: "\n")
    }
}

struct ValidatedEditPlan: Equatable, Sendable {
    var summary: String
    var changes: [ValidatedFileChange]
}

enum AgentError: LocalizedError, Equatable {
    case noWorkspace
    case noModel
    case provider(String)
    case malformedResponse
    case unsafePath(String)
    case staleFile(String)
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .noWorkspace: "Choose an approved workspace first."
        case .noModel: "Enter the model name exposed by the configured API."
        case .provider(let message): message
        case .malformedResponse: "The model did not return a valid file edit plan."
        case .unsafePath(let path): "The model proposed an unsafe path: \(path)"
        case .staleFile(let path): "\(path) changed after the preview. Generate a fresh plan."
        case .unsupportedFile(let path): "\(path) is not a supported UTF-8 text file."
        }
    }
}

actor AgentModelService {
    private let decoder = JSONDecoder()

    func makePlan(configuration: AgentProviderConfiguration, apiKey: String, instruction: String, context: String) async throws -> AgentEditPlan {
        let system = """
        You are a careful file editor. Return JSON only, with this exact shape:
        {"summary":"short explanation","changes":[{"path":"relative/path","original":"complete current UTF-8 contents or null for a new file","replacement":"complete desired UTF-8 contents or null to delete","rationale":"reason"}]}
        Only change files inside the supplied workspace. Paths must be relative and must never contain '..'. Preserve unrelated content. If no edit is required, return an empty changes array.
        """
        let prompt = "WORKSPACE FILES:\n\(context)\n\nUSER REQUEST:\n\(instruction)"
        let content: String
        switch configuration.kind {
        case .apple:
            guard case .available = SystemLanguageModel.default.availability else {
                throw AgentError.provider("Apple Intelligence is unavailable on this Mac. Configure an OpenAI-compatible provider instead.")
            }
            let session = LanguageModelSession(instructions: system)
            content = try await session.respond(to: prompt).content
        case .openAICompatible:
            guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.noModel }
            content = try await requestOpenAICompatible(configuration: configuration, apiKey: apiKey, system: system, prompt: prompt)
        }
        return try decodePlan(content)
    }

    func test(configuration: AgentProviderConfiguration, apiKey: String) async throws -> String {
        if configuration.kind == .apple {
            guard case .available = SystemLanguageModel.default.availability else {
                throw AgentError.provider("Apple Intelligence is unavailable.")
            }
            return "Apple Intelligence is available"
        }
        let response = try await requestOpenAICompatible(configuration: configuration, apiKey: apiKey, system: "Reply concisely.", prompt: "Reply with exactly: ToskVoice connected")
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodePlan(_ content: String) throws -> AgentEditPlan {
        var value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = value.data(using: .utf8), let plan = try? decoder.decode(AgentEditPlan.self, from: data) else {
            throw AgentError.malformedResponse
        }
        return plan
    }

    private func requestOpenAICompatible(configuration: AgentProviderConfiguration, apiKey: String, system: String, prompt: String) async throws -> String {
        let base = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let responsesURL = URL(string: base + "/responses") else { throw AgentError.provider("The provider URL is invalid.") }
        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "instructions": system,
            "input": prompt,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let text = Self.responsesText(data) { return text }

        guard let chatURL = URL(string: base + "/chat/completions") else { throw AgentError.provider("The provider URL is invalid.") }
        request.url = chatURL
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.1,
        ])
        let (chatData, chatResponse) = try await URLSession.shared.data(for: request)
        guard let http = chatResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = Self.providerMessage(chatData)
            throw AgentError.provider(message ?? "The provider rejected the request.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: chatData) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw AgentError.malformedResponse }
        return text
    }

    private static func responsesText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = object["output_text"] as? String { return text }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where (part["type"] as? String) == "output_text" {
                if let text = part["text"] as? String { return text }
            }
        }
        return nil
    }

    private static func providerMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

actor WorkspaceEditEngine {
    private struct UndoEntry: Sendable {
        var url: URL
        var data: Data?
    }
    private var undoEntries: [UndoEntry] = []

    func buildContext(root: URL) throws -> String {
        let manager = FileManager.default
        let ignored = Set([".git", ".build", "node_modules", "DerivedData", ".obsidian/plugins"])
        let allowedExtensions = Set(["swift", "md", "txt", "json", "yaml", "yml", "toml", "js", "jsx", "ts", "tsx", "css", "html", "py", "rs", "go", "java", "kt", "c", "h", "cpp", "hpp", "sh", "zsh", "rb"])
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return "" }
        var sections: [String] = []
        var total = 0
        for case let url as URL in enumerator {
            let relative = relativePath(url, root: root)
            if ignored.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                enumerator.skipDescendants()
                continue
            }
            guard allowedExtensions.contains(url.pathExtension.lowercased()) || url.lastPathComponent == "Makefile" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 80_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let section = "<<<FILE \(relative)>>>\n\(text)\n<<<END FILE>>>"
            guard total + section.count <= 180_000 else { break }
            sections.append(section)
            total += section.count
        }
        return sections.joined(separator: "\n\n")
    }

    func validate(plan: AgentEditPlan, root: URL) throws -> ValidatedEditPlan {
        var seen = Set<String>()
        let changes = try plan.changes.map { change -> ValidatedFileChange in
            let url = try safeURL(relativePath: change.path, root: root)
            guard seen.insert(change.path).inserted else { throw AgentError.unsafePath(change.path) }
            let currentData = try? Data(contentsOf: url)
            let currentText = currentData.flatMap { String(data: $0, encoding: .utf8) }
            if currentData != nil && currentText == nil { throw AgentError.unsupportedFile(change.path) }
            guard currentText == change.original else { throw AgentError.staleFile(change.path) }
            return ValidatedFileChange(
                relativePath: change.path,
                original: change.original,
                replacement: change.replacement,
                rationale: change.rationale,
                originalDigest: currentData.map(Self.digest)
            )
        }
        return ValidatedEditPlan(summary: plan.summary, changes: changes)
    }

    func apply(_ plan: ValidatedEditPlan, root: URL) throws {
        var transaction: [UndoEntry] = []
        do {
            for change in plan.changes {
                let url = try safeURL(relativePath: change.relativePath, root: root)
                let current = try? Data(contentsOf: url)
                guard current.map(Self.digest) == change.originalDigest else { throw AgentError.staleFile(change.relativePath) }
                transaction.append(UndoEntry(url: url, data: current))
                if let replacement = change.replacement {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(replacement.utf8).write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            undoEntries = transaction
        } catch {
            try? restore(transaction.reversed())
            throw error
        }
    }

    func undo() throws {
        guard !undoEntries.isEmpty else { return }
        try restore(undoEntries.reversed())
        undoEntries = []
    }

    private func restore<S: Sequence>(_ entries: S) throws where S.Element == UndoEntry {
        for entry in entries {
            if let data = entry.data {
                try FileManager.default.createDirectory(at: entry.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: entry.url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: entry.url.path) {
                try FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    private func safeURL(relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw AgentError.unsafePath(relativePath)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        let canonicalParent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        guard canonicalParent.path == canonicalRoot.path || canonicalParent.path.hasPrefix(canonicalRoot.path + "/") else {
            throw AgentError.unsafePath(relativePath)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            let canonicalTarget = target.resolvingSymlinksInPath()
            guard canonicalTarget.path.hasPrefix(canonicalRoot.path + "/") else { throw AgentError.unsafePath(relativePath) }
        }
        return target
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class VoiceEditorAgentController: ObservableObject {
    @Published var instruction = ""
    @Published var status = "Choose a workspace and describe a change"
    @Published var plan: ValidatedEditPlan?
    @Published var isWorking = false
    @Published var apiKey: String

    let preferences: AgentPreferencesStore
    private let models = AgentModelService()
    private let engine = WorkspaceEditEngine()
    private let speaker = AVSpeechSynthesizer()
    private var activeRoot: URL?
    private var activeSecurityScope = false

    init(preferences: AgentPreferencesStore) {
        self.preferences = preferences
        apiKey = KeychainCredentialStore.loadAPIKey()
    }

    deinit {
        if activeSecurityScope { activeRoot?.stopAccessingSecurityScopedResource() }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Approve Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try preferences.addWorkspace(url: url); status = "Approved \(url.lastPathComponent)" }
        catch { status = error.localizedDescription }
    }

    func saveAPIKey() {
        do { try KeychainCredentialStore.saveAPIKey(apiKey); status = "Credential saved in Keychain" }
        catch { status = error.localizedDescription }
    }

    func installObsidianCompanion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Obsidian Vault"
        panel.message = "Select the root folder of an Obsidian vault."
        guard panel.runModal() == .OK, let vault = panel.url else { return }
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Integrations/obsidian"),
              FileManager.default.fileExists(atPath: source.path) else {
            status = "The Obsidian companion is missing from this build."
            return
        }
        let destination = vault.appendingPathComponent(".obsidian/plugins/tosk-voice", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            status = "Installed companion — enable ToskVoice in Obsidian Community Plugins"
        } catch { status = error.localizedDescription }
    }

    func copyZedConfiguration() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/toskvoice-agent").path
        let snippet = """
        "agent_servers": {
          "toskvoice": {
            "type": "custom",
            "command": "\(helper)",
            "args": [],
            "env": {}
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        status = "Zed agent_servers configuration copied"
    }

    func testProvider() {
        isWorking = true
        status = "Testing provider…"
        Task {
            do { status = try await models.test(configuration: preferences.provider, apiKey: apiKey) }
            catch { status = error.localizedDescription }
            isWorking = false
        }
    }

    func run() {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let workspace = preferences.selectedWorkspace else { status = AgentError.noWorkspace.localizedDescription; return }
        isWorking = true
        plan = nil
        status = "Reading approved workspace…"
        Task {
            do {
                let root = try resolve(workspace)
                let context = try await engine.buildContext(root: root)
                guard !context.isEmpty else { throw AgentError.provider("No supported text files were found in this workspace.") }
                status = "Asking \(preferences.provider.kind.label)…"
                let proposed = try await models.makePlan(
                    configuration: preferences.provider,
                    apiKey: apiKey,
                    instruction: instruction,
                    context: context
                )
                let validated = try await engine.validate(plan: proposed, root: root)
                plan = validated
                status = validated.changes.isEmpty ? validated.summary : "\(validated.changes.count) change(s) ready"
                if workspace.approvalMode == .autoApply, !validated.changes.isEmpty { apply() }
                else { speak(validated.summary) }
            } catch { status = error.localizedDescription }
            isWorking = false
        }
    }

    func apply() {
        guard let plan, let root = activeRoot else { return }
        isWorking = true
        Task {
            do {
                try await engine.apply(plan, root: root)
                status = "Applied \(plan.changes.count) change(s) — Undo is available"
                speak(plan.summary)
            } catch { status = error.localizedDescription }
            isWorking = false
        }
    }

    func undo() {
        Task {
            do { try await engine.undo(); status = "Last editor transaction undone" }
            catch { status = error.localizedDescription }
        }
    }

    private func resolve(_ workspace: AgentWorkspace) throws -> URL {
        if activeSecurityScope { activeRoot?.stopAccessingSecurityScopedResource() }
        var stale = false
        let url = try URL(resolvingBookmarkData: workspace.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw AgentError.provider("Workspace access expired. Remove and approve the folder again.") }
        activeRoot = url
        activeSecurityScope = true
        return url
    }

    private func speak(_ value: String) {
        guard preferences.provider.speakResponses, !value.isEmpty else { return }
        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: value))
    }
}
