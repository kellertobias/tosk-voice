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
                Button(controller.isSpeaking ? "Stop" : "Play") {
                    controller.isSpeaking ? controller.stop() : controller.play()
                }
                .buttonStyle(.borderedProminent)
                Button("Generate MP3…") { controller.exportAudio() }
            }
            CopyableStatusText(text: controller.status)
            TextEditor(text: $controller.text)
                .font(.body)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                if let advanced = controller.advancedEngine {
                    Picker("Model", selection: Binding(
                        get: { controller.engineChoice == .system ? TTSEngineChoice.system : advanced },
                        set: { controller.engineChoice = $0 }
                    )) {
                        Text("Built-In").tag(TTSEngineChoice.system)
                        Text("Advanced (\(preferences.ttsProvider.label))").tag(advanced)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }
                voiceControls
            }
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 440)
        .onChange(of: preferences.ttsProvider) { alignEngineChoice() }
        .onChange(of: preferences.ttsServer.isConfigured) { alignEngineChoice() }
        .onAppear { alignEngineChoice() }
    }

    /// Falls back to the built-in engine when the configured provider can no
    /// longer serve the current selection.
    private func alignEngineChoice() {
        guard controller.engineChoice != .system else { return }
        if controller.engineChoice != controller.advancedEngine {
            controller.engineChoice = controller.advancedEngine ?? .system
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
