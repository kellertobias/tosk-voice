import AppKit
import SwiftUI

@MainActor
final class TextToSpeechWindowController {
    private var window: NSWindow?
    private let controller: TextToSpeechController

    init(modelPacks: ModelPackController, preferences: PreferencesStore) {
        controller = TextToSpeechController(modelPacks: modelPacks, preferences: preferences)
    }

    func show() {
        controller.captureSelectionSource()
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: TextToSpeechView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ToskVoice — Text to Speech"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct TextToSpeechView: View {
    @ObservedObject var controller: TextToSpeechController

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
                Button("Export WAV or MP3…") { controller.exportSystemAudio() }
                Spacer()
            }
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 440)
    }
}
