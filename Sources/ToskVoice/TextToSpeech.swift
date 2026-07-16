import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import TTSKit

enum TTSEngineChoice: Hashable {
    case system
    case neural
    case server
}

@MainActor
final class TextToSpeechController: ObservableObject {
    @Published var text = ""
    @Published var engineChoice: TTSEngineChoice = .system
    @Published var selectedVoiceIdentifier = AVSpeechSynthesisVoice(language: "en-US")?.identifier ?? ""
    @Published var rate: Double = 0.5
    @Published var status = "Ready"
    @Published var isSpeaking = false

    let modelPacks: ModelPackController
    let preferences: PreferencesStore
    let managedServer = ManagedTTSServer()
    let installer = TTSServerInstaller()
    private let synthesizer = AVSpeechSynthesizer()
    private var neuralTask: Task<Void, Never>?
    private var playbackEngine: AVAudioEngine?
    private var playbackNode: AVAudioPlayerNode?
    private var temporaryPlaybackURL: URL?
    private var selectionSourcePID: pid_t?

    init(modelPacks: ModelPackController, preferences: PreferencesStore) {
        self.modelPacks = modelPacks
        self.preferences = preferences
    }

    var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") || $0.language.hasPrefix("de") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func captureSelectionSource() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        selectionSourcePID = app.processIdentifier
    }

    func useCurrentSelection() {
        guard let processID = selectionSourcePID else { status = "Return to an app, select text, then reopen Text to Speech"; return }
        let application = AXUIElementCreateApplication(processID)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused as! AXUIElement? else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let selection = value as? String, !selection.isEmpty else { status = "No selected text was found"; return }
        text = selection
        status = "Selection loaded"
    }

    func openTextFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch { status = error.localizedDescription }
    }

    /// Plays with the engine selected in the model dropdown.
    func play() {
        switch engineChoice {
        case .system: speakSystem()
        case .neural: speakNeural()
        case .server: speakServer()
        }
    }

    func speakSystem() {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if preferences.selectedOutputUID != nil {
            let content = text
            let voice = selectedVoiceIdentifier
            let speechRate = rate
            isSpeaking = true
            status = "Preparing selected output…"
            neuralTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
                    try await writeSystemSpeech(content, voice: voice, rate: speechRate, to: temporary)
                    try play(file: temporary)
                } catch {
                    isSpeaking = false
                    status = error.localizedDescription
                }
            }
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier)
        utterance.rate = Float(rate)
        synthesizer.speak(utterance)
        isSpeaking = true
        status = "Speaking with macOS voice"
    }

    func speakNeural() {
        stop()
        let content = text
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSpeaking = true
        status = "Preparing neural voice…"
        neuralTask = Task { [weak self] in
            do {
                guard let self else { return }
                let kit = try await modelPacks.prepareNeuralVoice()
                status = "Speaking with neural voice"
                let languageCode = voices.first(where: { $0.identifier == selectedVoiceIdentifier })?.language ?? "en"
                let language = languageCode.hasPrefix("de") ? "german" : "english"
                let result = try await kit.generate(text: content, voice: nil, language: language)
                try play(samples: result.audio, sampleRate: result.sampleRate)
            } catch {
                self?.isSpeaking = false
                self?.status = error.localizedDescription
            }
        }
    }

    /// Speaks through the configured OpenAI-compatible speech server
    /// (XTTS v2, Fish-Speech, or any /v1/audio/speech implementation).
    func speakServer() {
        stop()
        let content = text
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let configuration = preferences.ttsServer
        guard let endpoint = configuration.speechEndpoint else {
            status = "Configure the TTS server URL first"
            return
        }
        isSpeaking = true
        status = "Requesting server voice…"
        neuralTask = Task { [weak self] in
            do {
                guard let self else { return }
                let data = try await serverAudio(for: content, configuration: configuration, endpoint: endpoint)
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("wav")
                try data.write(to: temporary)
                try play(file: temporary)
                status = "Speaking with server voice"
            } catch {
                self?.isSpeaking = false
                self?.status = error.localizedDescription
            }
        }
    }

    /// Requests synthesized WAV audio from the configured server, starting
    /// the managed server first when needed.
    private func serverAudio(for content: String, configuration: TTSServerConfiguration, endpoint: URL) async throws -> Data {
        guard await ensureManagedServer(configuration) else {
            throw TTSError.audioOutputFailed(managedServer.state.label)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = configuration.apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let voice = configuration.voice.trimmingCharacters(in: .whitespaces)
        var body: [String: Any]
        switch configuration.apiStyle {
        case .openAI:
            body = [
                "model": configuration.model.isEmpty ? "tts-1" : configuration.model,
                "input": content,
                "response_format": "wav",
            ]
            if !voice.isEmpty { body["voice"] = voice }
        case .fishSpeech:
            body = [
                "text": content,
                "format": "wav",
                "streaming": false,
            ]
            if !voice.isEmpty { body["reference_id"] = voice }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw TTSError.audioOutputFailed("The TTS server answered with an error: \(detail)")
        }
        return data
    }

    /// Installs a server preset and, on success, applies its configuration
    /// (keeping the existing API key and auto-start choice).
    func setUpServer(_ preset: TTSServerPreset) {
        installer.install(preset, huggingFaceToken: preferences.ttsServer.huggingFaceToken) { [weak self] in
            guard let self else { return }
            let previous = preferences.ttsServer
            var config = preset.configuration(autoStart: previous.autoStart)
            config.apiKey = previous.apiKey
            config.huggingFaceToken = previous.huggingFaceToken
            preferences.ttsServer = config
            status = "\(preset.label) configured — Server Voice is ready"
        }
    }

    /// Starts the managed server at app launch when configured to.
    func autoStartManagedServerIfEnabled() {
        let config = preferences.ttsServer
        guard config.autoStart,
              !config.managedCommand.trimmingCharacters(in: .whitespaces).isEmpty,
              !managedServer.isRunning else { return }
        managedServer.start(command: config.managedCommand, healthURL: config.healthProbeURL)
    }

    /// Launches the managed server when one is configured and waits until it
    /// answers. Returns false (with a status message) when it cannot start.
    private func ensureManagedServer(_ configuration: TTSServerConfiguration) async -> Bool {
        guard !configuration.managedCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        if managedServer.state == .running { return true }
        if managedServer.state != .starting {
            managedServer.start(command: configuration.managedCommand, healthURL: configuration.healthProbeURL)
        }
        status = "Starting managed TTS server…"
        while managedServer.state == .starting, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
        if managedServer.state == .running { return true }
        status = managedServer.state.label
        return false
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        neuralTask?.cancel()
        neuralTask = nil
        playbackNode?.stop()
        playbackEngine?.stop()
        playbackNode = nil
        playbackEngine = nil
        if let temporaryPlaybackURL { try? FileManager.default.removeItem(at: temporaryPlaybackURL) }
        temporaryPlaybackURL = nil
        isSpeaking = false
        status = "Ready"
    }

    /// Exports the current text as MP3 or WAV with the selected engine.
    func exportAudio() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ToskVoice.mp3"
        panel.allowedContentTypes = [.mp3, .wav]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        status = "Generating audio…"
        Task {
            do {
                let temporary = try await renderWav()
                if destination.pathExtension.lowercased() == "mp3" {
                    try encodeMP3(wav: temporary, destination: destination)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: temporary, to: destination)
                }
                try? FileManager.default.removeItem(at: temporary)
                status = "Saved \(destination.lastPathComponent)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    /// Synthesizes the current text with the selected engine into a
    /// temporary WAV file.
    private func renderWav() async throws -> URL {
        let content = text
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSError.audioOutputFailed("Enter some text first.")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        switch engineChoice {
        case .system:
            try await writeSystemSpeech(content, voice: selectedVoiceIdentifier, rate: rate, to: temporary)
        case .neural:
            let kit = try await modelPacks.prepareNeuralVoice()
            let languageCode = voices.first(where: { $0.identifier == selectedVoiceIdentifier })?.language ?? "en"
            let language = languageCode.hasPrefix("de") ? "german" : "english"
            let result = try await kit.generate(text: content, voice: nil, language: language)
            try Self.writeWav(samples: result.audio, sampleRate: result.sampleRate, to: temporary)
        case .server:
            let configuration = preferences.ttsServer
            guard let endpoint = configuration.speechEndpoint else {
                throw TTSError.audioOutputFailed("Configure the TTS server in Settings → Models first.")
            }
            let data = try await serverAudio(for: content, configuration: configuration, endpoint: endpoint)
            try data.write(to: temporary)
        }
        return temporary
    }

    private static func writeWav(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee else {
            throw TTSError.audioOutputFailed("The generated audio buffer was invalid.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func writeSystemSpeech(_ text: String, voice: String, rate: Double, to url: URL) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice)
        utterance.rate = Float(rate)
        let writer = AVSpeechSynthesizer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var output: AVAudioFile?
            var completed = false
            writer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                do {
                    if pcm.frameLength == 0 {
                        guard !completed else { return }
                        completed = true
                        continuation.resume()
                    } else {
                        if output == nil {
                            output = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
                        }
                        try output?.write(from: pcm)
                    }
                } catch {
                    guard !completed else { return }
                    completed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func encodeMP3(wav: URL, destination: URL) throws {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("lame")
        let candidates = [bundled, URL(fileURLWithPath: "/opt/homebrew/bin/lame"), URL(fileURLWithPath: "/usr/local/bin/lame")].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw TTSError.audioOutputFailed("MP3 export requires the bundled LAME encoder. Install it with `brew install lame` and rebuild the app.")
        }
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--silent", "--preset", "standard", wav.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TTSError.audioOutputFailed("LAME failed with exit code \(process.terminationStatus).") }
    }

    private func play(file: URL) throws {
        let audioFile = try AVAudioFile(forReading: file)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: audioFile.processingFormat)
        try AudioDeviceManager.configureOutput(preferences.selectedOutputUID, for: engine)
        engine.prepare()
        try engine.start()
        playbackEngine = engine
        playbackNode = node
        temporaryPlaybackURL = file
        node.scheduleFile(audioFile, at: nil) { [weak self] in
            Task { @MainActor in self?.finishPlayback() }
        }
        node.play()
        status = "Speaking on selected output"
    }

    private func play(samples: [Float], sampleRate: Int) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee else {
            throw TTSError.audioOutputFailed("The generated audio buffer was invalid.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try AudioDeviceManager.configureOutput(preferences.selectedOutputUID, for: engine)
        engine.prepare()
        try engine.start()
        playbackEngine = engine
        playbackNode = node
        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in self?.finishPlayback() }
        }
        node.play()
        status = "Speaking with neural voice"
    }

    private func finishPlayback() {
        playbackEngine?.stop()
        playbackNode = nil
        playbackEngine = nil
        if let temporaryPlaybackURL { try? FileManager.default.removeItem(at: temporaryPlaybackURL) }
        temporaryPlaybackURL = nil
        isSpeaking = false
        status = "Ready"
    }
}
