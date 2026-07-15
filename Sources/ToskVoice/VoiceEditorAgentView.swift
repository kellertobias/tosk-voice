import AppKit
import SwiftUI

@MainActor
final class VoiceEditorAgentWindowController {
    private var window: NSWindow?
    private let controller: VoiceEditorAgentController

    init(preferences: AgentPreferencesStore) {
        controller = VoiceEditorAgentController(preferences: preferences)
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: VoiceEditorAgentView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ToskVoice — Voice Editor"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 700))
        window.minSize = NSSize(width: 760, height: 580)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func show(instruction: String) {
        controller.instruction = instruction
        show()
    }

    func installObsidianCompanion() {
        controller.installObsidianCompanion()
    }

    func copyZedConfiguration() {
        controller.copyZedConfiguration()
    }
}

private struct VoiceEditorAgentView: View {
    @ObservedObject var controller: VoiceEditorAgentController
    @ObservedObject private var preferences: AgentPreferencesStore
    @State private var selectedChangeID: String?

    init(controller: VoiceEditorAgentController) {
        self.controller = controller
        preferences = controller.preferences
    }

    var body: some View {
        HSplitView {
            configuration
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 360)
            editor
                .frame(minWidth: 460)
        }
        .frame(minWidth: 760, minHeight: 580)
    }

    private var configuration: some View {
        Form {
            Section("Workspace") {
                Picker("Approved root", selection: $preferences.selectedWorkspaceID) {
                    Text("Choose…").tag(nil as UUID?)
                    ForEach(preferences.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id as UUID?)
                    }
                }
                HStack {
                    Button("Add Folder…") { controller.chooseWorkspace() }
                    Button("Remove") { preferences.removeSelectedWorkspace() }
                        .disabled(preferences.selectedWorkspace == nil)
                }
                if let workspace = preferences.selectedWorkspace {
                    Text(workspace.displayPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Picker("Changes", selection: Binding(
                        get: { workspace.approvalMode },
                        set: { preferences.setApprovalMode($0) }
                    )) {
                        ForEach(AgentApprovalMode.allCases) { Text($0.label).tag($0) }
                    }
                }
            }

            Section("Model provider") {
                Picker("Provider", selection: $preferences.provider.kind) {
                    ForEach(AgentProviderKind.allCases) { Text($0.label).tag($0) }
                }
                if preferences.provider.kind == .openAICompatible {
                    TextField("Base URL", text: $preferences.provider.baseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $preferences.provider.model)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API key (optional locally)", text: $controller.apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Key in Keychain") { controller.saveAPIKey() }
                }
                Toggle("Speak concise result", isOn: $preferences.provider.speakResponses)
                Button("Test Provider") { controller.testProvider() }
                    .disabled(controller.isWorking)
            }

            Section("Safety") {
                Label("Only approved workspace roots", systemImage: "folder.badge.gearshape")
                Label("No shell or network tools", systemImage: "lock.shield")
                Label("Atomic writes with undo", systemImage: "arrow.uturn.backward.circle")
            }

            Section("Editor integrations") {
                Button("Install Obsidian Companion…") { controller.installObsidianCompanion() }
                Button("Copy Zed Agent Configuration") { controller.copyZedConfiguration() }
                Text("The Obsidian command hands the current selection to this review window. Zed can run the bundled ACP helper in its Agent Panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe the file change").font(.headline)
            TextEditor(text: $controller.instruction)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 150)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Generate Changes") { controller.run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isWorking || preferences.selectedWorkspace == nil || controller.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if controller.isWorking { ProgressView().controlSize(.small) }
                Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Undo Last Apply") { controller.undo() }
            }

            Divider()
            if let plan = controller.plan {
                Text(plan.summary).font(.headline)
                if plan.changes.isEmpty {
                    ContentUnavailableView("No changes proposed", systemImage: "checkmark.circle")
                } else {
                    Picker("File", selection: Binding(
                        get: { selectedChangeID ?? plan.changes.first?.id },
                        set: { selectedChangeID = $0 }
                    )) {
                        ForEach(plan.changes) { Text($0.relativePath).tag($0.id as String?) }
                    }
                    if let change = selectedChange(in: plan) {
                        if let rationale = change.rationale, !rationale.isEmpty {
                            Text(rationale).font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView([.vertical, .horizontal]) {
                            Text(change.diff)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Spacer()
                        Button("Apply \(plan.changes.count) Change\(plan.changes.count == 1 ? "" : "s")") { controller.apply() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.isWorking)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No edit preview",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("ToskVoice sends only the supported text files inside your approved root to the selected model.")
                )
            }
        }
        .padding(20)
    }

    private func selectedChange(in plan: ValidatedEditPlan) -> ValidatedFileChange? {
        plan.changes.first { $0.id == selectedChangeID } ?? plan.changes.first
    }
}
