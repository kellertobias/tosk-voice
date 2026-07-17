import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: String {
    case general = "General"
    case dictation = "Dictation"
    case models = "Models"
    case textToSpeech = "Text to Speech"
    case privacy = "Privacy"
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
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
    private let ttsController: TextToSpeechController

    init(model: AppModel, ttsController: TextToSpeechController) {
        self.model = model
        self.ttsController = ttsController
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
            ttsController: ttsController,
            navigation: navigation
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
    let ttsController: TextToSpeechController
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var preferences: PreferencesStore
    @ObservedObject private var modelPacks: ModelPackController
    @StateObject private var permissions = PermissionCenter()

    init(
        model: AppModel,
        ttsController: TextToSpeechController,
        navigation: SettingsNavigation
    ) {
        self.model = model
        self.ttsController = ttsController
        self.navigation = navigation
        _preferences = ObservedObject(wrappedValue: model.preferences)
        _modelPacks = ObservedObject(wrappedValue: model.modelPacks)
    }

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            general.tag(SettingsTab.general).tabItem { Label("General", systemImage: "gearshape") }
            dictation.tag(SettingsTab.dictation).tabItem { Label("Dictation", systemImage: "mic") }
            models.tag(SettingsTab.models).tabItem { Label("Models", systemImage: "waveform.badge.magnifyingglass") }
            textToSpeech.tag(SettingsTab.textToSpeech).tabItem { Label("Text to Speech", systemImage: "speaker.wave.2.bubble") }
            privacy.tag(SettingsTab.privacy).tabItem { Label("Privacy", systemImage: "hand.raised") }
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
            Section("Edit with Voice") {
                Picker("Improve Result with", selection: Binding(
                    get: { preferences.improvement.provider },
                    set: { preferences.improvement.provider = $0 }
                )) {
                    ForEach(ImprovementProviderKind.allCases) { Text($0.label).tag($0) }
                }
                if preferences.improvement.provider == .openAICompatible {
                    TextField("Server URL", text: Binding(
                        get: { preferences.improvement.baseURL },
                        set: { preferences.improvement.baseURL = $0 }
                    ), prompt: Text("http://localhost:11434 or …/v1"))
                    TextField("Model", text: Binding(
                        get: { preferences.improvement.model },
                        set: { preferences.improvement.model = $0 }
                    ), prompt: Text("llama3.1, gpt-4.1-mini, …"))
                    SecureField("API Key (optional)", text: Binding(
                        get: { preferences.improvement.apiKey },
                        set: { preferences.improvement.apiKey = $0 }
                    ))
                    Text("Any OpenAI-compatible chat endpoint works: Ollama, mlx-lm, LM Studio, or OpenAI itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("“Improve Result” removes filler words, stutters, and other verbal artifacts from the text in the Edit with Voice window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Picker("Keep dictations for", selection: $preferences.historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                }
                Text("Older entries are removed automatically. Applies to the History window; already-saved files are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private var dictation: some View {
        Form {
            Section {
                Picker("Overlay position", selection: $preferences.overlayPlacement) {
                    ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Multi-speaker labels", isOn: $preferences.diarizationEnabled)
                Text("The dictation language is switched directly in the dictation overlay or the menu-bar menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcript processing") {
                Toggle("Spoken corrections", isOn: $preferences.spokenCorrectionsEnabled)
                Text("Apply phrases such as “oh no,” “strike that,” and “let me rephrase” to the staged text immediately using a warm on-device model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Polish final text", isOn: $preferences.condensedOutputEnabled)
                Text("On Stop, Apple’s on-device language model merges corrections and returns a concise final version. The original is kept if processing fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Vocabulary") {
                TextEditor(text: Binding(
                    get: { preferences.glossary.joined(separator: "\n") },
                    set: { preferences.glossary = $0.split(separator: "\n").map(String.init) }
                ))
                .font(.body.monospaced())
                .frame(minHeight: 110)
                Text("One name or domain term per line — applied to Quick Dictation, Edit with Voice, and Meeting Transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var models: some View {
        Form {
            Section("Apple Speech") {
                LabeledContent("English and German", value: "Managed by macOS")
                Text("Language assets download automatically the first time they are used.")
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
            Section("Model per feature") {
                transcriptionModelPicker("Quick Dictation", selection: $preferences.quickDictationModel)
                transcriptionModelPicker("Edit with Voice", selection: $preferences.editWithVoiceModel)
                Picker("Meeting Transcript", selection: $preferences.meetingTranscriptModel) {
                    Text(TranscriptionModelChoice.appleSpeech.label).tag(TranscriptionModelChoice.appleSpeech)
                }
                Text("Only downloaded and installed models can be selected. Meeting Transcript always uses Apple Speech — WhisperKit cannot transcribe the system-audio lane.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Model picker for one feature; WhisperKit is only offered once its
    /// pack is downloaded and set up.
    private func transcriptionModelPicker(_ title: String, selection: Binding<TranscriptionModelChoice>) -> some View {
        let whisperAvailable = modelPacks.whisperAvailable
        return Picker(title, selection: selection) {
            Text(TranscriptionModelChoice.appleSpeech.label).tag(TranscriptionModelChoice.appleSpeech)
            if whisperAvailable || selection.wrappedValue == .whisperBilingual {
                Text(TranscriptionModelChoice.whisperBilingual.label).tag(TranscriptionModelChoice.whisperBilingual)
            }
        }
    }

    private var textToSpeech: some View {
        Form {
            Section("Engine") {
                Picker("Use", selection: $preferences.ttsProvider) {
                    ForEach(TTSProviderChoice.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: preferences.ttsProvider) { applyProviderDefaults() }
            }
            switch preferences.ttsProvider {
            case .builtInOnly:
                Section {
                    LabeledContent("Options", value: "None")
                    Text("Uses the voices built into macOS — nothing to install or configure. Voice and rate are chosen in the Text to Speech window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .qwen3Neural:
                Section {
                    ModelPackRow(
                        title: "Qwen3 neural voice",
                        state: modelPacks.neuralVoiceState,
                        buttonTitle: "Install or Load Neural Voice..."
                    ) {
                        Task {
                            do { _ = try await modelPacks.prepareNeuralVoice() } catch { }
                        }
                    }
                    Text("Downloads from the Argmax model repository and runs fully on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .fish, .xtts:
                TTSServerSettingsSection(
                    preferences: preferences,
                    managed: ttsController.managedServer,
                    installer: ttsController.installer,
                    controller: ttsController
                )
            }
        }
        .formStyle(.grouped)
    }

    /// Keeps the server configuration in line with the chosen provider so
    /// the Text to Speech window can use it directly.
    private func applyProviderDefaults() {
        guard let engine = preferences.ttsProvider.serverEngine else { return }
        var config = preferences.ttsServer
        config.engine = engine
        if config.mode == .off { config.mode = .local }
        config.apiStyle = engine.apiStyle
        if config.mode == .local {
            let preset: TTSServerPreset = engine == .fish ? .fishSpeech : .xtts
            let defaults = preset.configuration(autoStart: config.autoStart)
            config.baseURL = defaults.baseURL
            config.model = defaults.model
            config.managedCommand = defaults.managedCommand
        }
        preferences.ttsServer = config
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
                CopyableStatusText(text: errorMessage, color: .red)
            }
        }
    }
}

/// Settings → Text to Speech section for the Fish-Speech / XTTS server
/// providers: choose local (installed and managed by ToskVoice) or remote,
/// install a local server, and control auto-start. The TTS window itself
/// only selects the model and voice.
private struct TTSServerSettingsSection: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var managed: ManagedTTSServer
    @ObservedObject var installer: TTSServerInstaller
    let controller: TextToSpeechController
    @State private var showingFishAssistant = false

    var body: some View {
        Section(preferences.ttsServer.engine == .fish ? "Fish-Speech" : "XTTS v2") {
            Picker("Mode", selection: binding(\.mode)) {
                Text(TTSServerMode.local.label).tag(TTSServerMode.local)
                Text(TTSServerMode.remote.label).tag(TTSServerMode.remote)
            }
            .pickerStyle(.segmented)
            .onChange(of: preferences.ttsServer.mode) { applyEngineDefaults() }

            if preferences.ttsServer.mode == .remote {
                remoteControls
            } else {
                localControls
            }
        }
        .sheet(isPresented: $showingFishAssistant) {
            FishSetupAssistant(
                token: binding(\.huggingFaceToken),
                installer: installer,
                onInstall: { controller.setUpServer(.fishSpeech) }
            )
        }
    }

    @ViewBuilder
    private var localControls: some View {
        let preset: TTSServerPreset = preferences.ttsServer.engine == .fish ? .fishSpeech : .xtts
        if preset.isInstalled, !installer.state.isRunning {
            HStack {
                LabeledContent(preset.label, value: "Installed")
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            HStack {
                Button("Install \(preset.label)…") { confirmInstall(preset) }
                    .disabled(installer.state.isRunning || managed.isRunning)
                if installer.state.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { installer.cancel() }
                }
            }
        }
        if installer.state != .idle {
            CopyableStatusText(
                text: installer.state.label,
                color: { if case .failed = installer.state { .red } else { nil } }()
            )
            if installer.state.isRunning, let line = installer.recentOutput.last {
                Text(line).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        if preferences.ttsServer.engine == .xtts ? TTSServerPreset.xtts.isInstalled : TTSServerPreset.fishSpeech.isInstalled {
        Toggle("Start the server automatically when ToskVoice launches", isOn: binding(\.autoStart))
            .disabled(preferences.ttsServer.managedCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        LabeledContent("Server status") {
            HStack {
                CopyableStatusText(
                    text: managed.state.label,
                    color: { if case .failed = managed.state { .red } else { nil } }()
                )
                Button(managed.isRunning ? "Stop Server" : "Start Server") {
                    if managed.isRunning {
                        managed.stop()
                    } else {
                        managed.start(
                            command: preferences.ttsServer.managedCommand,
                            healthURL: preferences.ttsServer.healthProbeURL
                        )
                    }
                }
                .font(.body)
                .disabled(preferences.ttsServer.managedCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.caption)
        }
    }

    @ViewBuilder
    private var remoteControls: some View {
        TextField("Server URL", text: binding(\.baseURL), prompt: Text("https://gpu-box:8080 or …/v1"))
        if preferences.ttsServer.engine == .xtts {
            TextField("Model", text: binding(\.model), prompt: Text("tts-1-hd"))
        }
        SecureField("API Key (optional)", text: binding(\.apiKey))
        Text("Run the server with your preferred precision (FP16, or FP8 on CUDA hardware) — ToskVoice just sends the text.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func confirmInstall(_ preset: TTSServerPreset) {
        // Fish-Speech needs a gated Hugging Face model, so it gets the guided
        // assistant; XTTS installs directly after a confirmation.
        if preset == .fishSpeech {
            showingFishAssistant = true
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install \(preset.label)?"
        alert.informativeText = preset.summary + "\n\nOn success, the server is configured automatically."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.setUpServer(preset)
    }

    /// Applies engine-appropriate defaults after a mode or engine change.
    private func applyEngineDefaults() {
        var config = preferences.ttsServer
        guard config.mode != .off else { return }
        config.apiStyle = config.engine.apiStyle
        switch config.mode {
        case .local:
            let preset: TTSServerPreset = config.engine == .fish ? .fishSpeech : .xtts
            let defaults = preset.configuration(autoStart: config.autoStart)
            config.baseURL = defaults.baseURL
            config.model = defaults.model
            config.managedCommand = defaults.managedCommand
            config.apiStyle = defaults.apiStyle
        case .remote:
            config.managedCommand = ""
            config.autoStart = false
            if config.engine == .xtts, config.model.isEmpty { config.model = "tts-1-hd" }
        case .off:
            break
        }
        preferences.ttsServer = config
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TTSServerConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.ttsServer[keyPath: keyPath] },
            set: { preferences.ttsServer[keyPath: keyPath] = $0 }
        )
    }
}

/// Guided Fish-Speech setup: leads the user through accepting the gated
/// model's license and pasting a Hugging Face access token, then installs.
/// No terminal required.
private struct FishSetupAssistant: View {
    @Binding var token: String
    @ObservedObject var installer: TTSServerInstaller
    let onInstall: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var acceptedLicense = false

    private let licenseURL = URL(string: "https://huggingface.co/fishaudio/openaudio-s1-mini")!
    private let tokenURL = URL(string: "https://huggingface.co/settings/tokens")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Fish-Speech")
                .font(.title2.bold())
            Text("Fish-Speech's voice model is hosted on Hugging Face and needs a free account. ToskVoice will download and configure everything — just two one-time steps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(number: 1, title: "Accept the model license") {
                Text("Open the model page and click the button to accept its license (you'll need to be signed in to Hugging Face).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Model License Page") { NSWorkspace.shared.open(licenseURL) }
                    Toggle("I accepted the license", isOn: $acceptedLicense)
                        .toggleStyle(.checkbox)
                }
            }

            step(number: 2, title: "Paste a Hugging Face access token") {
                Text("Create a free “Read” token, then paste it here. ToskVoice stores it and uses it only to download the model.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    SecureField("hf_…", text: $token)
                        .textFieldStyle(.roundedBorder)
                    Button("Get a Token") { NSWorkspace.shared.open(tokenURL) }
                }
            }

            if installer.state.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    CopyableStatusText(text: installer.state.label)
                }
                if let line = installer.recentOutput.last {
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
            } else if case .failed(let message) = installer.state {
                CopyableStatusText(text: message, color: .red)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Cancel") {
                    if installer.state.isRunning { installer.cancel() }
                    dismiss()
                }
                Spacer()
                Button("Download & Install") { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canInstall)
            }
        }
        .padding(22)
        .frame(width: 520, height: 460)
        .onChange(of: installer.state) {
            if case .succeeded = installer.state { dismiss() }
        }
    }

    private var canInstall: Bool {
        acceptedLicense
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !installer.state.isRunning
    }

    @ViewBuilder
    private func step(number: Int, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.headline)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.tint.opacity(0.2)))
                Text(title).font(.headline)
            }
            content()
                .padding(.leading, 32)
        }
    }
}
