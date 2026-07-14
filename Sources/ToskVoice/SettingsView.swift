import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(model: model)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "ToskVoice Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 540))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: PreferencesStore
    @StateObject private var permissions = PermissionCenter()
    @State private var selectedTab = "Profiles"

    init(model: AppModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            general.tag("General").tabItem { Label("General", systemImage: "gearshape") }
            profiles.tag("Profiles").tabItem { Label("Profiles", systemImage: "square.stack.3d.up") }
            models.tag("Models").tabItem { Label("Models", systemImage: "waveform.badge.magnifyingglass") }
            privacy.tag("Privacy").tabItem { Label("Privacy", systemImage: "hand.raised") }
            extensions.tag("Extensions").tabItem { Label("Extensions", systemImage: "sparkles") }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var general: some View {
        Form {
            Section("Shortcuts") {
                Picker("Toggle dictation", selection: $preferences.toggleShortcut) {
                    ForEach(ToggleShortcutChoice.allCases) { Text($0.label).tag($0) }
                }
                Picker("Push to talk", selection: $preferences.pushShortcut) {
                    ForEach(PushShortcutChoice.allCases) { Text($0.label).tag($0) }
                }
                Text("Shortcut changes take effect immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Picker("Microphone", selection: Binding(get: { preferences.selectedInputUID ?? "" }, set: { preferences.selectedInputUID = $0.isEmpty ? nil : $0 })) {
                    Text("System Default").tag("")
                    ForEach(model.inputDevices) { Text($0.name).tag($0.uid) }
                }
                Picker("Output", selection: Binding(get: { preferences.selectedOutputUID ?? "" }, set: { preferences.selectedOutputUID = $0.isEmpty ? nil : $0 })) {
                    Text("System Default").tag("")
                    ForEach(model.outputDevices) { Text($0.name).tag($0.uid) }
                }
            }
            Section {
                Toggle("Launch ToskVoice at login", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { value in
                        preferences.launchAtLogin = value
                        do { value ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch { }
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }

    private var profiles: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                List(selection: $preferences.selectedProfileID) {
                    ForEach(preferences.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                HStack {
                    Button { preferences.addProfile() } label: { Image(systemName: "plus") }
                    Button { preferences.deleteSelectedProfile() } label: { Image(systemName: "minus") }
                        .disabled(preferences.profiles.count == 1)
                    Spacer()
                }
            }
            .frame(width: 190)
            Divider()
            ProfileEditor(preferences: preferences)
        }
    }

    private var models: some View {
        Form {
            Section("Apple Speech") {
                LabeledContent("English and German", value: "Managed by macOS")
                Text("Language assets download automatically the first time a profile uses them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatic English + German") {
                LabeledContent("WhisperKit Large-v3 Turbo", value: model.modelPacks.whisperState.label)
                Button("Install or Load Model Pack…") {
                    Task { _ = try? await model.modelPacks.prepareWhisper() }
                }
                .disabled(model.modelPacks.whisperState == .downloading || model.modelPacks.whisperState == .loading)
                Text("Downloaded directly from the Argmax model repository and cached locally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speaker labels") {
                LabeledContent("SpeakerKit", value: model.modelPacks.speakerState.label)
                Button("Install or Load Speaker Pack…") {
                    Task { _ = try? await model.modelPacks.prepareSpeakerKit() }
                }
                .disabled(model.modelPacks.speakerState == .downloading || model.modelPacks.speakerState == .loading)
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("Local by default") {
                Label("Microphone audio is processed on this Mac.", systemImage: "checkmark.shield")
                Label("Raw audio is discarded after each dictation.", systemImage: "checkmark.shield")
                Label("Transcript history stays in Application Support.", systemImage: "externaldrive")
            }
            Section("Required permissions") {
                permissionRow(
                    title: "Microphone",
                    explanation: "Captures speech and drives the waveform.",
                    granted: permissions.microphoneGranted,
                    request: { Task { await permissions.requestMicrophone() } },
                    pane: "Privacy_Microphone"
                )
                permissionRow(
                    title: "Input Monitoring",
                    explanation: "Listens for dictation shortcuts while another app is active.",
                    granted: permissions.inputMonitoringGranted,
                    request: permissions.requestInputMonitoring,
                    pane: "Privacy_ListenEvent"
                )
                permissionRow(
                    title: "Accessibility",
                    explanation: "Inserts the finished transcript into the focused text field.",
                    granted: permissions.accessibilityGranted,
                    request: permissions.requestAccessibility,
                    pane: "Privacy_Accessibility"
                )
                Text("After granting Input Monitoring or Accessibility, quit and reopen ToskVoice so macOS applies the change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var extensions: some View {
        Form {
            Section("Text to Speech") {
                Label("macOS and optional Qwen3 voices", systemImage: "checkmark.circle")
                Label("Selectable output and WAV/MP3 export", systemImage: "checkmark.circle")
            }
            Section("Voice Editor Agent") {
                Label("Apple and OpenAI-compatible providers", systemImage: "checkmark.circle")
                Label("Approved roots, native diff review, atomic undo", systemImage: "checkmark.circle")
                Label("Bundled Zed ACP and Obsidian companion", systemImage: "checkmark.circle")
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        title: String,
        explanation: String,
        granted: Bool,
        request: @escaping () -> Void,
        pane: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Spacer()
                Text(granted ? "Granted" : "Not granted")
                    .foregroundStyle(.secondary)
                if !granted { Button("Request Access", action: request) }
                Button("Open Settings") { permissions.openPrivacySettings(pane) }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProfileEditor: View {
    @ObservedObject var preferences: PreferencesStore

    private var profile: Binding<DictationProfile> {
        Binding(get: { preferences.selectedProfile }, set: { preferences.selectedProfile = $0 })
    }

    var body: some View {
        Form {
            TextField("Name", text: profile.name)
            Picker("Language", selection: profile.speechMode) {
                ForEach(SpeechMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Destination", selection: profile.destination) {
                ForEach(DestinationKind.allCases) { Text($0.label).tag($0) }
            }
            if profile.wrappedValue.destination == .markdown {
                LabeledContent("File", value: profile.wrappedValue.markdownDisplayPath ?? "Not selected")
                Button("Choose Markdown File…") { chooseMarkdown() }
            }
            Picker("Overlay position", selection: profile.overlayPlacement) {
                ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Multi-speaker labels", isOn: profile.diarizationEnabled)
            VStack(alignment: .leading, spacing: 6) {
                Text("Vocabulary").font(.headline)
                TextEditor(text: Binding(
                    get: { profile.wrappedValue.glossary.joined(separator: "\n") },
                    set: { profile.wrappedValue.glossary = $0.split(separator: "\n").map(String.init) }
                ))
                .font(.body.monospaced())
                .frame(minHeight: 110)
                Text("One name or domain term per line.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Dictation.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            profile.wrappedValue.markdownBookmark = data
            profile.wrappedValue.markdownDisplayPath = url.path
        }
    }
}
