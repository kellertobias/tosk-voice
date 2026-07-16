import AppKit
import SwiftUI

@MainActor
final class TextToSpeechWindowController {
    private var window: NSWindow?
    private let controller: TextToSpeechController

    init(modelPacks: ModelPackController, preferences: PreferencesStore) {
        controller = TextToSpeechController(modelPacks: modelPacks, preferences: preferences)
    }

    /// Opens the window with text supplied by the system Services menu.
    func show(text: String) {
        show()
        controller.text = text
    }

    func show() {
        controller.captureSelectionSource()
        if let window {
            DockPresence.shared.track(window)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: TextToSpeechView(
            controller: controller,
            preferences: controller.preferences,
            managed: controller.managedServer
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ToskVoice — Text to Speech"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        DockPresence.shared.track(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct TextToSpeechView: View {
    @ObservedObject var controller: TextToSpeechController
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var managed: ManagedTTSServer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Use Selection") { controller.useCurrentSelection() }
                Button("Open Text File…") { controller.openTextFile() }
                Spacer()
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $controller.text)
                .font(.body)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Picker("Voice", selection: $controller.selectedVoiceIdentifier) {
                    ForEach(controller.voices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(voice.language)").tag(voice.identifier)
                    }
                }
                Slider(value: $controller.rate, in: 0.25...0.65) { Text("Rate") }
                    .frame(width: 150)
            }
            HStack {
                Button(controller.isSpeaking ? "Stop" : "Speak") {
                    controller.isSpeaking ? controller.stop() : controller.speakSystem()
                }
                .buttonStyle(.borderedProminent)
                Button("Neural Voice") { controller.speakNeural() }
                Button("Server Voice") { controller.speakServer() }
                    .disabled(!preferences.ttsServer.isConfigured)
                    .help("Speak through the configured OpenAI-compatible TTS server (XTTS v2, Fish-Speech, …)")
                Button("Export WAV or MP3…") { controller.exportSystemAudio() }
                Spacer()
            }
            DisclosureGroup("TTS Server (XTTS v2, Fish-Speech, …)") {
                serverConfiguration
            }
            .font(.callout)
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 440)
    }

    private var serverConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Any OpenAI-compatible speech endpoint works: xtts-api-server or openedai-speech for XTTS v2, Fish-Speech's API server, and similar. Run the server with your preferred precision (FP16 locally, FP8 on CUDA hardware) — the app just sends the text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("API")
                    Picker("", selection: apiStyleBinding) {
                        ForEach(TTSServerAPIStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)
                }
                GridRow {
                    Text("Server URL")
                    TextField("http://localhost:8000 or https://gpu-box:8020/v1", text: serverBinding(\.baseURL))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Model")
                    TextField("tts-1, xtts-v2, fish-speech-1.5…", text: serverBinding(\.model))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Voice")
                    TextField("Voice or reference speaker name (optional)", text: serverBinding(\.voice))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("API Key")
                    SecureField("Optional", text: serverBinding(\.apiKey))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Divider().padding(.vertical, 4)
            managedServerSection
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var managedServerSection: some View {
        Text("Managed server: ToskVoice launches this command (login shell, so uv/uvx work), waits until the URL above answers, and stops it on quit. Example: cd ~/src/fish-speech && uv run tools/api_server.py --listen 127.0.0.1:8080 --half")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            TextField("Launch command (leave empty to manage the server yourself)", text: serverBinding(\.managedCommand))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .disabled(managed.isRunning)
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
            .disabled(!managed.isRunning && preferences.ttsServer.managedCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        HStack(spacing: 6) {
            Circle()
                .fill(managedTintColor(managed.state))
                .frame(width: 8, height: 8)
            Text(managed.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let lastLine = managed.recentOutput.last {
                Text(lastLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func managedTintColor(_ state: ManagedTTSServer.State) -> Color {
        switch state {
        case .stopped: .gray
        case .starting: .yellow
        case .running: .green
        case .failed: .red
        }
    }

    private var apiStyleBinding: Binding<TTSServerAPIStyle> {
        Binding(
            get: { preferences.ttsServer.apiStyle },
            set: { preferences.ttsServer.apiStyle = $0 }
        )
    }

    private func serverBinding(_ keyPath: WritableKeyPath<TTSServerConfiguration, String>) -> Binding<String> {
        Binding(
            get: { preferences.ttsServer[keyPath: keyPath] },
            set: { preferences.ttsServer[keyPath: keyPath] = $0 }
        )
    }
}
