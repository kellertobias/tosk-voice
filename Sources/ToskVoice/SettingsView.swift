import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String {
    case general = "General"
    case profiles = "Profiles"
    case models = "Models"
    case privacy = "Privacy"
    case extensions = "Extensions"
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedTab: SettingsTab = .profiles
}

enum SettingsRelaunchState {
    private static let tabKey = "settings.reopenAfterRestart.tab"

    @MainActor
    static func prepare(selectedTab: SettingsTab, defaults: UserDefaults = .standard) {
        defaults.set(selectedTab.rawValue, forKey: tabKey)
    }

    @MainActor
    static func consumeSelectedTab(defaults: UserDefaults = .standard) -> SettingsTab? {
        defer { defaults.removeObject(forKey: tabKey) }
        guard let rawValue = defaults.string(forKey: tabKey) else { return nil }
        return SettingsTab(rawValue: rawValue)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let navigation = SettingsNavigation()
    private let model: AppModel
    private let showTextToSpeech: @MainActor () -> Void
    private let showVoiceEditor: @MainActor () -> Void
    private let installObsidianCompanion: @MainActor () -> Void
    private let copyZedConfiguration: @MainActor () -> Void

    init(
        model: AppModel,
        showTextToSpeech: @escaping @MainActor () -> Void,
        showVoiceEditor: @escaping @MainActor () -> Void,
        installObsidianCompanion: @escaping @MainActor () -> Void,
        copyZedConfiguration: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.showTextToSpeech = showTextToSpeech
        self.showVoiceEditor = showVoiceEditor
        self.installObsidianCompanion = installObsidianCompanion
        self.copyZedConfiguration = copyZedConfiguration
    }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            navigation.selectedTab = tab
        }
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(
            model: model,
            navigation: navigation,
            showTextToSpeech: showTextToSpeech,
            showVoiceEditor: showVoiceEditor,
            installObsidianCompanion: installObsidianCompanion,
            copyZedConfiguration: copyZedConfiguration
        )
        let controller = NSHostingController(rootView: view)
        let window = SettingsWindow(contentViewController: controller)
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

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              key == "q" || key == "w"
        else {
            return super.performKeyEquivalent(with: event)
        }

        close()
        return true
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var preferences: PreferencesStore
    @ObservedObject private var modelPacks: ModelPackController
    @StateObject private var permissions = PermissionCenter()
    private let showTextToSpeech: @MainActor () -> Void
    private let showVoiceEditor: @MainActor () -> Void
    private let installObsidianCompanion: @MainActor () -> Void
    private let copyZedConfiguration: @MainActor () -> Void

    init(
        model: AppModel,
        navigation: SettingsNavigation,
        showTextToSpeech: @escaping @MainActor () -> Void,
        showVoiceEditor: @escaping @MainActor () -> Void,
        installObsidianCompanion: @escaping @MainActor () -> Void,
        copyZedConfiguration: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.navigation = navigation
        self.showTextToSpeech = showTextToSpeech
        self.showVoiceEditor = showVoiceEditor
        self.installObsidianCompanion = installObsidianCompanion
        self.copyZedConfiguration = copyZedConfiguration
        _preferences = ObservedObject(wrappedValue: model.preferences)
        _modelPacks = ObservedObject(wrappedValue: model.modelPacks)
    }

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            general.tag(SettingsTab.general).tabItem { Label("General", systemImage: "gearshape") }
            profiles.tag(SettingsTab.profiles).tabItem { Label("Profiles", systemImage: "square.stack.3d.up") }
            models.tag(SettingsTab.models).tabItem { Label("Models", systemImage: "waveform.badge.magnifyingglass") }
            privacy.tag(SettingsTab.privacy).tabItem { Label("Privacy", systemImage: "hand.raised") }
            extensions.tag(SettingsTab.extensions).tabItem { Label("Extensions", systemImage: "sparkles") }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
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
                ModelPackRow(
                    title: "WhisperKit Large-v3 Turbo",
                    state: modelPacks.whisperState,
                    buttonTitle: "Install or Load Model Pack..."
                ) {
                    Task {
                        do { _ = try await modelPacks.prepareWhisper() } catch { }
                    }
                }
                Text("Downloaded directly from the Argmax model repository and cached locally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speaker labels") {
                ModelPackRow(
                    title: "SpeakerKit",
                    state: modelPacks.speakerState,
                    buttonTitle: "Install or Load Speaker Pack..."
                ) {
                    Task {
                        do { _ = try await modelPacks.prepareSpeakerKit() } catch { }
                    }
                }
            }
            Section("Text to Speech") {
                ModelPackRow(
                    title: "Qwen3 neural voice",
                    state: modelPacks.neuralVoiceState,
                    buttonTitle: "Install or Load Neural Voice..."
                ) {
                    Task {
                        do { _ = try await modelPacks.prepareNeuralVoice() } catch { }
                    }
                }
                Text("macOS voices are managed by the system. The optional neural voice downloads from the Argmax model repository.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    title: "Accessibility",
                    explanation: "Inserts the listening marker and finished transcript into the focused field.",
                    granted: permissions.accessibilityGranted,
                    request: permissions.requestAccessibility,
                    pane: "Privacy_Accessibility"
                )
                HStack(alignment: .center, spacing: 12) {
                    Text("After granting Accessibility, restart ToskVoice so macOS applies the change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        SettingsRelaunchState.prepare(selectedTab: navigation.selectedTab)
                        permissions.restartApplication()
                    } label: {
                        Label("Restart ToskVoice", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var extensions: some View {
        Form {
            Section("Text to Speech") {
                ExtensionActionRow(title: "macOS and optional Qwen3 voices", systemImage: "checkmark.circle") {
                    Button("Open Text to Speech", action: showTextToSpeech)
                    Button("Download Qwen3 Voice") {
                        navigation.selectedTab = .models
                        Task {
                            do { _ = try await modelPacks.prepareNeuralVoice() } catch { }
                        }
                    }
                }
                ExtensionActionRow(title: "Selectable output and WAV/MP3 export", systemImage: "checkmark.circle") {
                    Button("Output Settings") {
                        navigation.selectedTab = .general
                    }
                    Button("Export Audio", action: showTextToSpeech)
                }
            }
            Section("Voice Editor Agent") {
                ExtensionActionRow(title: "Apple and OpenAI-compatible providers", systemImage: "checkmark.circle") {
                    Button("Provider Settings", action: showVoiceEditor)
                }
                ExtensionActionRow(title: "Approved roots, native diff review, atomic undo", systemImage: "checkmark.circle") {
                    Button("Workspace Settings", action: showVoiceEditor)
                }
                ExtensionActionRow(title: "Bundled Zed ACP and Obsidian companion", systemImage: "checkmark.circle") {
                    Button("Copy Zed Config", action: copyZedConfiguration)
                    Button("Install Obsidian", action: installObsidianCompanion)
                }
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

private struct ExtensionActionRow<Actions: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            HStack(spacing: 8, content: actions)
                .controlSize(.small)
        }
    }
}

private struct ModelPackRow: View {
    let title: String
    let state: ModelPackController.PackState
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabeledContent(title, value: state.label)
                if state.isReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if state.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 10) {
                Button(buttonTitle, action: action)
                    .disabled(state.isActive)
                if state.isActive {
                    if let progress = state.progressValue {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 170)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
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
            Section("Transcript processing") {
                Toggle("Spoken corrections", isOn: Binding(
                    get: { profile.wrappedValue.usesSpokenCorrections },
                    set: { profile.wrappedValue.spokenCorrectionsEnabled = $0 }
                ))
                Text("Apply phrases such as “oh no,” “strike that,” and “let me rephrase” to the staged text immediately using a warm on-device model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Polish final text", isOn: Binding(
                    get: { profile.wrappedValue.producesCondensedOutput },
                    set: { profile.wrappedValue.condensedOutputEnabled = $0 }
                ))
                Text("On Stop, Apple’s on-device language model merges corrections and returns a concise final version. The original is kept if processing fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
