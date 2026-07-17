@preconcurrency import AVFoundation
import Foundation

/// Microphone-only transcription session for the Dictation Editor: one
/// SpeechAnalyzer lane fed by an AVAudioEngine input tap. Two gates control
/// the audio flow — pause (the Pause button) and talk (closed in push-to-talk
/// mode while the key is up, always open in continuous mode).
@MainActor
final class DictationEditorSession {
    private let lane = MeetingTranscriptionLane()
    private var engine: AVAudioEngine?
    private let pauseGate = PauseGate()
    private let talkGate = PauseGate()

    var isRunning: Bool { engine != nil }

    var isPaused: Bool {
        get { pauseGate.isPaused }
        set { pauseGate.isPaused = newValue }
    }

    /// True while push-to-talk withholds audio (mode is PTT and the key is up).
    var isTalkGated: Bool {
        get { talkGate.isPaused }
        set { talkGate.isPaused = newValue }
    }

    func start(
        locale: Locale,
        glossary: [String],
        inputUID: String?,
        onText: @escaping @MainActor (String, Bool, TimedUtterance?) -> Void,
        onLevel: @escaping @MainActor @Sendable (Float) -> Void
    ) async throws {
        guard !isRunning else { return }
        let audioEngine = AVAudioEngine()
        try AudioDeviceManager.configureInput(inputUID, for: audioEngine)
        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw SpeechSessionError.noMicrophone }
        do {
            let handler = try await lane.start(
                locale: locale,
                glossary: glossary,
                inputFormat: micFormat,
                onText: onText,
                onLevel: onLevel
            )
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: micFormat,
                block: Self.gated(handler, gates: [pauseGate, talkGate])
            )
            audioEngine.prepare()
            try audioEngine.start()
            engine = audioEngine
        } catch {
            await lane.cancel()
            throw error
        }
    }

    /// Stops the engine and finalizes the lane; pending final results are
    /// delivered through `onText` before this returns.
    func stop() async {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        await lane.finish()
    }

    func cancel() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        await lane.cancel()
    }

    private nonisolated static func gated(
        _ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        gates: [PauseGate]
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            guard !gates.contains(where: \.isPaused) else { return }
            handler(buffer, time)
        }
    }
}
