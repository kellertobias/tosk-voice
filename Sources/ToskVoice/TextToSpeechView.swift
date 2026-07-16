import AppKit
import SwiftUI

@MainActor
final class TextToSpeechWindowController {
    private var window: NSWindow?
    let controller: TextToSpeechController

    init(modelPacks: ModelPackController, preferences: PreferencesStore) {
        controller = TextToSpeechController(modelPacks: modelPacks, preferences: preferences)
    }

    /// Starts the managed TTS server at app launch when the user enabled it.
    func autoStartManagedServerIfEnabled() {
        controller.autoStartManagedServerIfEnabled()
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
            preferences: controller.preferences
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
                Picker("Model", selection: $controller.engineChoice) {
                    Text("macOS Voice").tag(TTSEngineChoice.system)
                    Text("Qwen3 Neural").tag(TTSEngineChoice.neural)
                    if preferences.ttsServer.isUsable {
                        Text(preferences.ttsServer.displayName).tag(TTSEngineChoice.server)
                    }
                }
                .frame(maxWidth: 280)
                voiceControls
            }
            HStack {
                Button(controller.isSpeaking ? "Stop" : "Play") {
                    controller.isSpeaking ? controller.stop() : controller.play()
                }
                .buttonStyle(.borderedProminent)
                Button("Generate MP3…") { controller.exportAudio() }
                Spacer()
            }
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 440)
        .onChange(of: preferences.ttsServer.isUsable) {
            if !preferences.ttsServer.isUsable, controller.engineChoice == .server {
                controller.engineChoice = .system
            }
        }
    }

    @ViewBuilder
    private var voiceControls: some View {
        switch controller.engineChoice {
        case .system, .neural:
            Picker("Voice", selection: $controller.selectedVoiceIdentifier) {
                ForEach(controller.voices, id: \.identifier) { voice in
                    Text("\(voice.name) — \(voice.language)").tag(voice.identifier)
                }
            }
            if controller.engineChoice == .system {
                Slider(value: $controller.rate, in: 0.25...0.65) { Text("Rate") }
                    .frame(width: 150)
            }
        case .server:
            TextField("Voice / reference ID (optional)", text: Binding(
                get: { preferences.ttsServer.voice },
                set: { preferences.ttsServer.voice = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
        }
    }
}
